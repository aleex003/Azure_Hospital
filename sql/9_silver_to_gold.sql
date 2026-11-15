SET NOCOUNT ON;

PRINT 'INICIANDO TRANSFORMACION SILVER A GOLD';

-- =====================================================
-- 1. LIMPIAR GOLD PARA PERMITIR NUEVAS EJECUCIONES
-- =====================================================

DELETE FROM gold.fact_facturacion;
DELETE FROM gold.fact_admisiones;

DELETE FROM gold.dim_diagnostico;
DELETE FROM gold.dim_servicio_cargo;
DELETE FROM gold.dim_departamento;
DELETE FROM gold.dim_paciente;
DELETE FROM gold.dim_fecha;

-- =====================================================
-- 2. DIMENSION PACIENTE
-- =====================================================

INSERT INTO gold.dim_paciente (
    patient_id_bk,
    nombre_completo,
    genero,
    fecha_nacimiento,
    rango_etario,
    correo_electronico,
    direccion,
    proveedor_seguro
)
SELECT
    patient_id,
    full_name,
    CASE
        WHEN gender = 'Male' THEN 'Masculino'
        WHEN gender = 'Female' THEN 'Femenino'
        ELSE 'Otro'
    END,
    date_of_birth,
    CASE
        WHEN date_of_birth IS NULL THEN 'Desconocido'
        WHEN DATEDIFF(YEAR, date_of_birth, GETDATE())
             - CASE
                 WHEN DATEADD(YEAR, DATEDIFF(YEAR, date_of_birth, GETDATE()),
                              date_of_birth) > CAST(GETDATE() AS DATE)
                 THEN 1 ELSE 0
               END <= 18 THEN '0-18'
        WHEN DATEDIFF(YEAR, date_of_birth, GETDATE()) <= 35 THEN '19-35'
        WHEN DATEDIFF(YEAR, date_of_birth, GETDATE()) <= 60 THEN '36-60'
        ELSE '60+'
    END,
    email,
    address,
    COALESCE(insurance_provider, 'Desconocido')
FROM silver.patients;

PRINT 'DIMENSION PACIENTE CARGADA';

-- =====================================================
-- 3. DIMENSION DEPARTAMENTO
-- =====================================================

INSERT INTO gold.dim_departamento (
    nombre_departamento
)
SELECT DISTINCT department
FROM silver.admissions;

PRINT 'DIMENSION DEPARTAMENTO CARGADA';

-- =====================================================
-- 4. DIMENSION DIAGNOSTICO
-- =====================================================

INSERT INTO gold.dim_diagnostico (
    codigo_icd,
    descripcion_patologia,
    nivel_severidad
)
SELECT DISTINCT
    icd_code,
    diagnosis_description,
    COALESCE(severity, 'Unknown')
FROM silver.diagnoses;

PRINT 'DIMENSION DIAGNOSTICO CARGADA';

-- =====================================================
-- 5. DIMENSION SERVICIO / CARGO
-- =====================================================

INSERT INTO gold.dim_servicio_cargo (
    tipo_cargo,
    estado_pago
)
SELECT DISTINCT
    charge_type,
    payment_status
FROM silver.billing;

PRINT 'DIMENSION SERVICIO CARGADA';

-- =====================================================
-- 6. DIMENSION FECHA
-- =====================================================

DECLARE @FechaInicio DATE;
DECLARE @FechaFin DATE;

SELECT
    @FechaInicio = MIN(Fecha),
    @FechaFin = MAX(Fecha)
FROM (
    SELECT admission_date AS Fecha
    FROM silver.admissions

    UNION ALL

    SELECT discharge_date
    FROM silver.admissions
    WHERE discharge_date IS NOT NULL

    UNION ALL

    SELECT payment_date
    FROM silver.billing
    WHERE payment_date IS NOT NULL
) F;

IF @FechaInicio IS NOT NULL
BEGIN

    ;WITH Calendario AS (
        SELECT @FechaInicio AS Fecha

        UNION ALL

        SELECT DATEADD(DAY, 1, Fecha)
        FROM Calendario
        WHERE Fecha < @FechaFin
    )

    INSERT INTO gold.dim_fecha (
        fecha_key,
        fecha_completa,
        anio,
        trimestre,
        trimestre_nombre,
        mes,
        mes_nombre,
        mes_corto,
        semana_anio,
        dia_mes,
        dia_semana,
        dia_nombre,
        es_fin_de_semana
    )
    SELECT
        CONVERT(INT, CONVERT(CHAR(8), Fecha, 112)),
        Fecha,
        YEAR(Fecha),
        DATEPART(QUARTER, Fecha),
        CONCAT('T', DATEPART(QUARTER, Fecha)),
        MONTH(Fecha),

        CASE MONTH(Fecha)
            WHEN 1 THEN 'Enero'
            WHEN 2 THEN 'Febrero'
            WHEN 3 THEN 'Marzo'
            WHEN 4 THEN 'Abril'
            WHEN 5 THEN 'Mayo'
            WHEN 6 THEN 'Junio'
            WHEN 7 THEN 'Julio'
            WHEN 8 THEN 'Agosto'
            WHEN 9 THEN 'Septiembre'
            WHEN 10 THEN 'Octubre'
            WHEN 11 THEN 'Noviembre'
            WHEN 12 THEN 'Diciembre'
        END,

        LEFT(
            CASE MONTH(Fecha)
                WHEN 1 THEN 'Ene'
                WHEN 2 THEN 'Feb'
                WHEN 3 THEN 'Mar'
                WHEN 4 THEN 'Abr'
                WHEN 5 THEN 'May'
                WHEN 6 THEN 'Jun'
                WHEN 7 THEN 'Jul'
                WHEN 8 THEN 'Ago'
                WHEN 9 THEN 'Sep'
                WHEN 10 THEN 'Oct'
                WHEN 11 THEN 'Nov'
                WHEN 12 THEN 'Dic'
            END, 3
        ),

        DATEPART(WEEK, Fecha),
        DAY(Fecha),

        ((DATEDIFF(DAY, '19000101', Fecha) % 7) + 1),

        CASE ((DATEDIFF(DAY, '19000101', Fecha) % 7) + 1)
            WHEN 1 THEN 'Lunes'
            WHEN 2 THEN 'Martes'
            WHEN 3 THEN 'Miercoles'
            WHEN 4 THEN 'Jueves'
            WHEN 5 THEN 'Viernes'
            WHEN 6 THEN 'Sabado'
            WHEN 7 THEN 'Domingo'
        END,

        CASE
            WHEN ((DATEDIFF(DAY, '19000101', Fecha) % 7) + 1)
                 IN (6, 7) THEN 1
            ELSE 0
        END

    FROM Calendario
    OPTION (MAXRECURSION 0);

END;

PRINT 'DIMENSION FECHA CARGADA';

-- =====================================================
-- 7. TABLA DE HECHOS: ADMISIONES
-- =====================================================

;WITH DiagnosticoPrincipal AS (
    SELECT
        admission_id,
        icd_code,
        diagnosis_description,
        severity,
        ROW_NUMBER() OVER (
            PARTITION BY admission_id
            ORDER BY diagnosis_id
        ) AS rn
    FROM silver.diagnoses
)

INSERT INTO gold.fact_admisiones (
    admission_id_bk,
    paciente_key,
    departamento_key,
    diagnostico_key,
    fecha_ingreso_key,
    fecha_alta_key,
    medico_id,
    dias_estancia,
    conteo_admisiones
)
SELECT
    a.admission_id,
    p.paciente_key,
    d.departamento_key,
    dg.diagnostico_key,
    CONVERT(INT, CONVERT(CHAR(8), a.admission_date, 112)),
    CASE
        WHEN a.discharge_date IS NOT NULL
        THEN CONVERT(INT, CONVERT(CHAR(8), a.discharge_date, 112))
        ELSE NULL
    END,
    a.attending_doctor_id,
    CASE
        WHEN a.discharge_date IS NOT NULL
        THEN DATEDIFF(DAY, a.admission_date, a.discharge_date)
        ELSE NULL
    END,
    1

FROM silver.admissions a

INNER JOIN gold.dim_paciente p
    ON p.patient_id_bk = a.patient_id

INNER JOIN gold.dim_departamento d
    ON d.nombre_departamento = a.department

INNER JOIN DiagnosticoPrincipal dp
    ON dp.admission_id = a.admission_id
   AND dp.rn = 1

INNER JOIN gold.dim_diagnostico dg
    ON dg.codigo_icd = dp.icd_code
   AND ISNULL(dg.descripcion_patologia, '') =
       ISNULL(dp.diagnosis_description, '')
   AND dg.nivel_severidad = COALESCE(dp.severity, 'Unknown');

PRINT 'HECHOS DE ADMISIONES CARGADOS';

-- =====================================================
-- 8. TABLA DE HECHOS: FACTURACION
-- =====================================================

INSERT INTO gold.fact_facturacion (
    billing_id_bk,
    admission_id_bk,
    paciente_key,
    departamento_key,
    servicio_cargo_key,
    fecha_pago_key,
    monto_facturado,
    conteo_transacciones
)
SELECT
    b.billing_id,
    a.admission_id,
    p.paciente_key,
    d.departamento_key,
    sc.servicio_cargo_key,

    CASE
        WHEN b.payment_date IS NOT NULL
        THEN CONVERT(INT, CONVERT(CHAR(8), b.payment_date, 112))
        ELSE NULL
    END,

    b.amount,
    1

FROM silver.billing b

INNER JOIN silver.admissions a
    ON a.admission_id = b.admission_id

INNER JOIN gold.dim_paciente p
    ON p.patient_id_bk = a.patient_id

INNER JOIN gold.dim_departamento d
    ON d.nombre_departamento = a.department

INNER JOIN gold.dim_servicio_cargo sc
    ON sc.tipo_cargo = b.charge_type
   AND sc.estado_pago = b.payment_status;

PRINT 'HECHOS DE FACTURACION CARGADOS';

PRINT 'TRANSFORMACION SILVER A GOLD FINALIZADA';