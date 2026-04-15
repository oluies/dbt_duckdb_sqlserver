/* MIGRATION V2: Landing Tables */

-- 1. Skapa Sekvens för Surrogate Key (DENNA VAR BORTKOMMENTERAD HOS DIG)
IF NOT EXISTS (SELECT * FROM sys.sequences WHERE name = 'household_seq' AND schema_id = SCHEMA_ID('finance'))
BEGIN
    CREATE SEQUENCE finance.household_seq 
        AS INT
        START WITH 1
        INCREMENT BY 1;
END
GO

-- 2. Skapa Landningstabell
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'stg_households_landing' AND schema_id = SCHEMA_ID('finance'))
BEGIN
    CREATE TABLE finance.stg_households_landing (
        -- Primary Key (Fylls automatiskt av sekvensen ovan)
        household_sk INT NOT NULL DEFAULT (NEXT VALUE FOR finance.household_seq),
        
        -- Data-kolumner
        household_bk NVARCHAR(255),
        source_file NVARCHAR(500),
        income_before_tax DECIMAL(18, 2), 
        debt_total DECIMAL(18, 2),
        
        -- De nya kolumnerna som vi lade till
        num_children INT,
        lti_credit_amount DECIMAL(18, 2),
        
        -- Audit-kolumner
        stg_loaded_at DATETIME2 DEFAULT SYSUTCDATETIME(),
        dbt_batch_id NVARCHAR(50),

        -- Constraints
        CONSTRAINT PK_stg_households_landing PRIMARY KEY CLUSTERED (household_sk)
    );
END
GO
