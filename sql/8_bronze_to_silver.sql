SET NOCOUNT ON;

PRINT 'INICIANDO TRANSFORMACION BRONZE A SILVER';

-- =====================================================
-- 1. PACIENTES
-- =====================================================

INSERT INTO silver.patients (
    patient_id,
    full_name,
    gender,
    date_of_birth,
    phone,
    email,
    address,
    insurance_provider
)
SELECT
    TRY_CONVERT(INT, patient_id),
    LTRIM(RTRIM(full_name)),
    CASE
        WHEN LOWER(LTRIM(RTRIM(gender))) IN ('m','male') THEN 'Male'
        WHEN LOWER(LTRIM(RTRIM(gender))) IN ('f','female') THEN 'Female'
        ELSE 'Other'
    END,
    COALESCE(
        TRY_CONVERT(DATE, date_of_birth, 23),
        TRY_CONVERT(DATE, date_of_birth, 101),
        TRY_CONVERT(DATE, date_of_birth, 110),
        TRY_CONVERT(DATE, date_of_birth, 106),
        TRY_CONVERT(DATE, date_of_birth, 107),
        TRY_CONVERT(DATE, date_of_birth, 0)
    ),
    NULLIF(LTRIM(RTRIM(phone)), 'unknown'),
    CASE
        WHEN email LIKE '%_@_%._%' AND email NOT LIKE '%,%'
             AND email NOT LIKE '% %'
        THEN LOWER(LTRIM(RTRIM(email)))
        ELSE NULL
    END,
    address,
    NULLIF(LTRIM(RTRIM(insurance_provider)), '')
FROM bronze.patients
WHERE TRY_CONVERT(INT, patient_id) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(full_name)), '') IS NOT NULL;

PRINT 'PACIENTES CARGADOS';


-- =====================================================
-- 2. ADMISIONES
-- =====================================================

INSERT INTO silver.admissions (
    admission_id,
    patient_id,
    admission_date,
    discharge_date,
    department,
    attending_doctor_id
)
SELECT
    a.admission_id,
    a.patient_id,
    a.fecha_ingreso,
    CASE
        WHEN a.fecha_alta >= a.fecha_ingreso
        THEN a.fecha_alta
        ELSE NULL
    END,
    a.departamento,
    a.doctor_id
FROM (
    SELECT
        TRY_CONVERT(INT, b.admission_id) AS admission_id,
        TRY_CONVERT(INT, b.patient_id) AS patient_id,

        COALESCE(
            TRY_CONVERT(DATE, b.admission_date, 23),
            TRY_CONVERT(DATE, b.admission_date, 101),
            TRY_CONVERT(DATE, b.admission_date, 110),
            TRY_CONVERT(DATE, b.admission_date, 106),
            TRY_CONVERT(DATE, b.admission_date, 107),
            TRY_CONVERT(DATE, b.admission_date, 0)
        ) AS fecha_ingreso,

        COALESCE(
            TRY_CONVERT(DATE, b.discharge_date, 23),
            TRY_CONVERT(DATE, b.discharge_date, 101),
            TRY_CONVERT(DATE, b.discharge_date, 110),
            TRY_CONVERT(DATE, b.discharge_date, 106),
            TRY_CONVERT(DATE, b.discharge_date, 107),
            TRY_CONVERT(DATE, b.discharge_date, 0)
        ) AS fecha_alta,

        CASE
            WHEN LOWER(b.department) LIKE '%onco%' THEN 'Oncology'
            WHEN LOWER(b.department) LIKE '%cardio%' THEN 'Cardiology'
            WHEN LOWER(b.department) LIKE '%ortho%' THEN 'Orthopedics'
            WHEN LOWER(b.department) LIKE '%neuro%' THEN 'Neurology'
            WHEN LOWER(b.department) LIKE '%pediatr%' THEN 'Pediatrics'
            WHEN LOWER(b.department) LIKE '%emerg%' 
                 OR LOWER(b.department) = 'er' THEN 'Emergency'
            WHEN LOWER(b.department) LIKE '%surg%' THEN 'General Surgery'
            ELSE 'Other'
        END AS departamento,

        TRY_CONVERT(INT, b.attending_doctor_id) AS doctor_id

    FROM bronze.admissions b
) a
INNER JOIN silver.patients p
    ON p.patient_id = a.patient_id
WHERE a.admission_id IS NOT NULL
  AND a.fecha_ingreso IS NOT NULL
  AND a.doctor_id IS NOT NULL;

PRINT 'ADMISIONES CARGADAS';


-- =====================================================
-- 3. DIAGNOSTICOS
-- =====================================================

INSERT INTO silver.diagnoses (
    diagnosis_id,
    admission_id,
    icd_code,
    diagnosis_description,
    severity
)
SELECT
    TRY_CONVERT(INT, d.diagnosis_id),
    TRY_CONVERT(INT, d.admission_id),
    UPPER(LTRIM(RTRIM(d.icd_code))),
    NULLIF(LTRIM(RTRIM(d.diagnosis_description)), ''),
    CASE
        WHEN LOWER(LTRIM(RTRIM(d.severity))) = 'mild' THEN 'Mild'
        WHEN LOWER(LTRIM(RTRIM(d.severity))) = 'moderate' THEN 'Moderate'
        WHEN LOWER(LTRIM(RTRIM(d.severity))) IN ('severe','severe ') THEN 'Severe'
        WHEN LOWER(LTRIM(RTRIM(d.severity))) = 'critical' THEN 'Critical'
        ELSE 'Unknown'
    END
FROM bronze.diagnoses d
INNER JOIN silver.admissions a
    ON a.admission_id = TRY_CONVERT(INT, d.admission_id)
WHERE TRY_CONVERT(INT, d.diagnosis_id) IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(d.icd_code)), '') IS NOT NULL;

PRINT 'DIAGNOSTICOS CARGADOS';


-- =====================================================
-- 4. FACTURACION
-- =====================================================

INSERT INTO silver.billing (
    billing_id,
    admission_id,
    charge_type,
    amount,
    payment_status,
    payment_date
)
SELECT
    TRY_CONVERT(INT, b.billing_id),
    TRY_CONVERT(INT, b.admission_id),

    COALESCE(
        NULLIF(LTRIM(RTRIM(b.charge_type)), ''),
        'Unknown'
    ),

    TRY_CONVERT(DECIMAL(12,2),
        REPLACE(
            REPLACE(
                REPLACE(
                    REPLACE(
                        LTRIM(RTRIM(b.amount)),
                        'USD', ''
                    ),
                    '$', ''
                ),
                ',', ''
            ),
            ' ', ''
        )
    ),

    CASE
        WHEN LOWER(LTRIM(RTRIM(b.payment_status))) = 'paid'
            THEN 'Paid'
        WHEN LOWER(LTRIM(RTRIM(b.payment_status))) = 'pending'
            THEN 'Pending'
        WHEN LOWER(LTRIM(RTRIM(b.payment_status))) = 'unpaid'
            THEN 'Unpaid'
        WHEN LOWER(LTRIM(RTRIM(b.payment_status))) = 'overdue'
            THEN 'Overdue'
        ELSE 'Unknown'
    END,

    COALESCE(
        TRY_CONVERT(DATE, b.payment_date, 23),
        TRY_CONVERT(DATE, b.payment_date, 101),
        TRY_CONVERT(DATE, b.payment_date, 110),
        TRY_CONVERT(DATE, b.payment_date, 106),
        TRY_CONVERT(DATE, b.payment_date, 107),
        TRY_CONVERT(DATE, b.payment_date, 0)
    )

FROM bronze.billing b
INNER JOIN silver.admissions a
    ON a.admission_id = TRY_CONVERT(INT, b.admission_id)

WHERE TRY_CONVERT(INT, b.billing_id) IS NOT NULL
  AND TRY_CONVERT(DECIMAL(12,2),
        REPLACE(REPLACE(REPLACE(REPLACE(
            LTRIM(RTRIM(b.amount)),
            'USD', ''), '$', ''), ',', ''), ' ', '')
      ) IS NOT NULL
  AND TRY_CONVERT(DECIMAL(12,2),
        REPLACE(REPLACE(REPLACE(REPLACE(
            LTRIM(RTRIM(b.amount)),
            'USD', ''), '$', ''), ',', ''), ' ', '')
      ) >= 0;

PRINT 'FACTURACION CARGADA';

PRINT 'TRANSFORMACION BRONZE A SILVER FINALIZADA';