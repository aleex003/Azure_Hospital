terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

# =========================================================
# 1. VARIABLE SEGURA PARA LA CONTRASEÑA DE AZURE SQL
# =========================================================

variable "sql_admin_password" {
  description = "Contraseña del administrador de Azure SQL"
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(var.sql_admin_password) >= 12 &&
      can(regex("[A-Z]", var.sql_admin_password)) &&
      can(regex("[a-z]", var.sql_admin_password)) &&
      can(regex("[0-9]", var.sql_admin_password)) &&
      can(regex("[^A-Za-z0-9]", var.sql_admin_password))
    )

    error_message = "La contraseña debe tener al menos 12 caracteres, mayúsculas, minúsculas, números y símbolos."
  }
}

# =========================================================
# 2. CONFIGURACIÓN DEL PROVEEDOR AZURE
# =========================================================

provider "azurerm" {
  features {}

  subscription_id = "02969b0a-2970-40db-b80d-11cca722bb09"
  use_cli         = true
}

# =========================================================
# 3. CONFIGURACIÓN DE SCRIPTS SQL
# =========================================================

locals {
  # Incrementar conscientemente para repetir la carga.
  # ATENCIÓN: el primer script puede eliminar tablas existentes.
  dw_seed_version = "1"

  dw_sql_scripts = [
    "1_bronze.sql",
    "2_silver.sql",
    "3_gold.sql",
    "4_insert_bronze_patients.sql",
    "5_insert_bronze_admissions.sql",
    "6_insert_bronze_diagnoses.sql",
    "7_insert_bronze_billing.sql",
  ]
}

# =========================================================
# 4. GRUPO DE RECURSOS
# =========================================================

resource "azurerm_resource_group" "rg" {
  name     = "gr-ucb-hospital"
  location = "brazilsouth"
}

# =========================================================
# 5. SERVIDOR AZURE SQL
# =========================================================

resource "azurerm_mssql_server" "sql_server" {
  name                         = "sql-ucb-hospital-alexandra-61482"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "franklin"
  administrator_login_password = var.sql_admin_password
  minimum_tls_version          = "1.2"
}

# =========================================================
# 6. FIREWALL: ACCESO SOLAMENTE DESDE TU IP
# =========================================================

resource "azurerm_mssql_firewall_rule" "allow_current_ip" {
  name             = "AllowAlexandraCurrentIP"
  server_id        = azurerm_mssql_server.sql_server.id
  start_ip_address = "166.114.139.213"
  end_ip_address   = "166.114.139.213"
}

# =========================================================
# 7. BASE DE DATOS DW_HOSPITAL
# =========================================================

resource "azurerm_mssql_database" "db" {
  for_each = toset(["dw_hospital"])

  name                        = each.value
  server_id                   = azurerm_mssql_server.sql_server.id
  collation                   = "SQL_Latin1_General_CP1_CI_AS"
  sku_name                    = "GP_S_Gen5_1"
  max_size_gb                 = 32
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = 60
}

# =========================================================
# 8. EJECUCIÓN AUTOMÁTICA DE SCRIPTS SQL
# =========================================================

resource "terraform_data" "dw_schema" {

  triggers_replace = [
    azurerm_mssql_database.db["dw_hospital"].id,
    local.dw_seed_version,
  ]

  depends_on = [
    azurerm_mssql_firewall_rule.allow_current_ip,
  ]

  lifecycle {
    precondition {
      condition = alltrue([
        for script in local.dw_sql_scripts :
        fileexists("${path.module}/sql/${script}")
      ])

      error_message = "Deben existir los siete scripts SQL dentro de la carpeta sql/."
    }
  }

  provisioner "local-exec" {

    interpreter = [
      "PowerShell",
      "-NoProfile",
      "-NonInteractive",
      "-Command"
    ]

    environment = {
      SQL_SERVER      = azurerm_mssql_server.sql_server.fully_qualified_domain_name
      SQL_DATABASE    = azurerm_mssql_database.db["dw_hospital"].name
      SQL_USER        = azurerm_mssql_server.sql_server.administrator_login
      SQLCMDPASSWORD  = var.sql_admin_password
      SQL_SCRIPT_DIR  = abspath("${path.module}/sql")
      SQL_SCRIPT_LIST = join(";", local.dw_sql_scripts)
    }

    command = <<-POWERSHELL

      $ErrorActionPreference = "Stop"

      # Localizar sqlcmd
      $sqlcmdCommand = Get-Command sqlcmd -ErrorAction SilentlyContinue |
        Select-Object -First 1

      $sqlcmd = if ($sqlcmdCommand) {
        $sqlcmdCommand.Source
      }
      elseif (Test-Path -LiteralPath "C:\Program Files\SqlCmd\sqlcmd.exe") {
        "C:\Program Files\SqlCmd\sqlcmd.exe"
      }
      else {
        throw "Instale sqlcmd antes de ejecutar Terraform."
      }

      # Parámetros de conexión
      $commonArgs = @(
        "-S", $env:SQL_SERVER,
        "-d", $env:SQL_DATABASE,
        "-U", $env:SQL_USER,
        "-b",
        "-r", "1",
        "-l", "30"
      )

      # Esperar a que Azure SQL esté disponible
      $connected = $false

      for ($attempt = 1; $attempt -le 12; $attempt++) {

        & $sqlcmd @commonArgs -Q "SET NOCOUNT ON; SELECT 1;" *> $null

        if ($LASTEXITCODE -eq 0) {
          $connected = $true
          break
        }

        Start-Sleep -Seconds 10
      }

      if (-not $connected) {
        throw "No se pudo conectar a la base DW después de crearla y configurar el firewall."
      }

      # Ejecutar los siete scripts SQL en orden
      foreach ($scriptName in $env:SQL_SCRIPT_LIST.Split(";")) {

        $scriptPath = Join-Path $env:SQL_SCRIPT_DIR $scriptName

        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
          throw "No existe el script SQL: $scriptPath"
        }

        Write-Host "Ejecutando $scriptName en $env:SQL_DATABASE"

        & $sqlcmd @commonArgs -i $scriptPath

        if ($LASTEXITCODE -ne 0) {
          throw "Fallo $scriptName (código $LASTEXITCODE)."
        }
      }

      Write-Host "Todos los scripts SQL se ejecutaron correctamente."

    POWERSHELL
  }
}

# =========================================================
# 9. AZURE DATA FACTORY
# =========================================================

resource "azurerm_data_factory" "adf" {
  name                = "adf-ucb-hospital-alexandra-61482"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "brazilsouth"
}