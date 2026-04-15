/* MIGRATION V1: Security & Schema Setup
   Syfte: Skapar användare, inloggning, scheman och tilldelar rättigheter.
   Ändrar inga tabeller.
*/

-- 1. Skapa Login (Server-nivå)
-- Detta kräver att du kör Flyway som 'sa' (vilket du gör i Makefilen)
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = 'fidemo_loader')
BEGIN
    CREATE LOGIN fidemo_loader WITH PASSWORD = 'StrongPassword456!';
END
GO

-- 2. Skapa User (Databas-nivå)
-- Kopplar server-inloggningen till denna specifika databas
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'fidemo_loader')
BEGIN
    CREATE USER fidemo_loader FOR LOGIN fidemo_loader;
END
GO

-- 3. Skapa Schema
-- Vi använder EXEC för att CREATE SCHEMA måste vara första satsen i en batch annars
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = 'finance')
BEGIN
    EXEC('CREATE SCHEMA [finance] AUTHORIZATION [dbo]')
END
GO

-- 4. Tilldela Rättigheter
-- Ger användaren rätt att läsa, skriva och modifiera objekt (DDL)
ALTER ROLE db_ddladmin ADD MEMBER fidemo_loader;
ALTER ROLE db_datareader ADD MEMBER fidemo_loader;
ALTER ROLE db_datawriter ADD MEMBER fidemo_loader;
GO

-- 5. Konfigurera User Defaults
-- Viktigt för att slippa skriva 'finance.' framför allt i framtiden
ALTER USER fidemo_loader WITH DEFAULT_SCHEMA = finance;
GO