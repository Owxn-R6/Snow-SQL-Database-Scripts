/*==============================================================================
    SQL Server Index Fragmentation Report + Rebuild Script
    Purpose:
        - Report index fragmentation across all online writable user databases
        - Rebuild indexes over a configurable fragmentation threshold
        - Log each attempted action

    Notes:
        - Run from master
        - Default mode is DRY RUN
        - Excludes system databases
        - Excludes heaps
        - Excludes disabled/hypothetical indexes
        - Uses SAMPLED scan mode by default
==============================================================================*/

USE master;
GO

SET NOCOUNT ON;

-------------------------------------------------------------------------------
-- CONFIGURATION
-------------------------------------------------------------------------------

DECLARE @FragmentationThreshold DECIMAL(5,2) = 20.00;
-- Change this later if needed, e.g. 30.00, 40.00, 60.00

DECLARE @MinimumPageCount INT = 100;
-- Avoid rebuilding tiny indexes where fragmentation is often not worth actioning

DECLARE @ScanMode NVARCHAR(20) = N'SAMPLED';
-- Options: LIMITED, SAMPLED, DETAILED
-- SAMPLED is usually a sensible balance for larger environments

DECLARE @ExecuteMaintenance BIT = 1;
-- 0 = Dry run/report only
-- 1 = Actually rebuild indexes

DECLARE @UseSortInTempDb BIT = 0;
-- 0 = SORT_IN_TEMPDB OFF
-- 1 = SORT_IN_TEMPDB ON
-- Only enable if tempdb has enough space and performance headroom

DECLARE @MaxDop INT = 0;
-- 0 = SQL Server default
-- Set to 1, 2, 4 etc. if you want to control rebuild CPU usage

-------------------------------------------------------------------------------
-- TEMP TABLES
-------------------------------------------------------------------------------

IF OBJECT_ID('tempdb..#IndexFragmentationReport') IS NOT NULL
    DROP TABLE #IndexFragmentationReport;

CREATE TABLE #IndexFragmentationReport
(
    ID INT IDENTITY(1,1) PRIMARY KEY,
    DatabaseName SYSNAME NOT NULL,
    SchemaName SYSNAME NOT NULL,
    TableName SYSNAME NOT NULL,
    IndexName SYSNAME NOT NULL,
    IndexID INT NOT NULL,
    IndexType NVARCHAR(60) NULL,
    FragmentationPercent DECIMAL(10,2) NOT NULL,
    PageCount BIGINT NOT NULL,
    PartitionNumber INT NULL,
    ActionRequired NVARCHAR(50) NOT NULL,
    MaintenanceCommand NVARCHAR(MAX) NULL
);

IF OBJECT_ID('tempdb..#MaintenanceLog') IS NOT NULL
    DROP TABLE #MaintenanceLog;

CREATE TABLE #MaintenanceLog
(
    LogID INT IDENTITY(1,1) PRIMARY KEY,
    DatabaseName SYSNAME NOT NULL,
    SchemaName SYSNAME NOT NULL,
    TableName SYSNAME NOT NULL,
    IndexName SYSNAME NOT NULL,
    FragmentationPercent DECIMAL(10,2) NOT NULL,
    PageCount BIGINT NOT NULL,
    MaintenanceCommand NVARCHAR(MAX) NOT NULL,
    ExecutionStatus NVARCHAR(30) NOT NULL,
    ErrorMessage NVARCHAR(MAX) NULL,
    StartTime DATETIME2 NULL,
    EndTime DATETIME2 NULL
);

-------------------------------------------------------------------------------
-- COLLECT FRAGMENTATION DATA FROM ALL ONLINE WRITABLE USER DATABASES
-------------------------------------------------------------------------------

DECLARE @DatabaseName SYSNAME;
DECLARE @SQL NVARCHAR(MAX);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE database_id > 4
  AND state_desc = 'ONLINE'
  AND is_read_only = 0
  AND user_access_desc = 'MULTI_USER'
ORDER BY name;

OPEN db_cursor;

FETCH NEXT FROM db_cursor INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SQL = N'
USE ' + QUOTENAME(@DatabaseName) + N';

INSERT INTO #IndexFragmentationReport
(
    DatabaseName,
    SchemaName,
    TableName,
    IndexName,
    IndexID,
    IndexType,
    FragmentationPercent,
    PageCount,
    PartitionNumber,
    ActionRequired,
    MaintenanceCommand
)
SELECT
    DB_NAME() AS DatabaseName,
    s.name AS SchemaName,
    t.name AS TableName,
    i.name AS IndexName,
    ips.index_id AS IndexID,
    ips.index_type_desc AS IndexType,
    CAST(ips.avg_fragmentation_in_percent AS DECIMAL(10,2)) AS FragmentationPercent,
    ips.page_count AS PageCount,
    ips.partition_number AS PartitionNumber,
    CASE
        WHEN ips.avg_fragmentation_in_percent >= @FragmentationThreshold THEN ''REBUILD''
        ELSE ''REPORT_ONLY''
    END AS ActionRequired,
    CASE
        WHEN ips.avg_fragmentation_in_percent >= @FragmentationThreshold THEN
            N''ALTER INDEX '' + QUOTENAME(i.name) +
            N'' ON '' + QUOTENAME(s.name) + N''.'' + QUOTENAME(t.name) +
            N'' REBUILD WITH (SORT_IN_TEMPDB = '' +
                CASE WHEN @UseSortInTempDb = 1 THEN N''ON'' ELSE N''OFF'' END +
            N'', MAXDOP = '' + CAST(@MaxDop AS NVARCHAR(10)) + N'');''
        ELSE NULL
    END AS MaintenanceCommand
FROM sys.dm_db_index_physical_stats
(
    DB_ID(),
    NULL,
    NULL,
    NULL,
    @ScanMode
) AS ips
INNER JOIN sys.indexes AS i
    ON ips.object_id = i.object_id
   AND ips.index_id = i.index_id
INNER JOIN sys.tables AS t
    ON ips.object_id = t.object_id
INNER JOIN sys.schemas AS s
    ON t.schema_id = s.schema_id
WHERE ips.index_id > 0
  AND ips.index_level = 0
  AND ips.alloc_unit_type_desc = ''IN_ROW_DATA''
  AND ips.page_count >= @MinimumPageCount
  AND i.name IS NOT NULL
  AND i.is_disabled = 0
  AND i.is_hypothetical = 0
ORDER BY
    ips.avg_fragmentation_in_percent DESC;
';

    EXEC sys.sp_executesql
        @SQL,
        N'@FragmentationThreshold DECIMAL(5,2),
          @MinimumPageCount INT,
          @ScanMode NVARCHAR(20),
          @UseSortInTempDb BIT,
          @MaxDop INT',
        @FragmentationThreshold = @FragmentationThreshold,
        @MinimumPageCount = @MinimumPageCount,
        @ScanMode = @ScanMode,
        @UseSortInTempDb = @UseSortInTempDb,
        @MaxDop = @MaxDop;

    FETCH NEXT FROM db_cursor INTO @DatabaseName;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;

-------------------------------------------------------------------------------
-- DISPLAY FULL REPORT BEFORE MAINTENANCE
-------------------------------------------------------------------------------

SELECT
    DatabaseName,
    SchemaName,
    TableName,
    IndexName,
    IndexType,
    FragmentationPercent,
    PageCount,
    PartitionNumber,
    ActionRequired,
    MaintenanceCommand
FROM #IndexFragmentationReport
ORDER BY
    ActionRequired DESC,
    FragmentationPercent DESC,
    DatabaseName,
    SchemaName,
    TableName,
    IndexName;

-------------------------------------------------------------------------------
-- PERFORM MAINTENANCE WHERE REQUIRED
-------------------------------------------------------------------------------

IF @ExecuteMaintenance = 1
BEGIN
    DECLARE
        @ID INT,
        @ActionDatabase SYSNAME,
        @ActionSchema SYSNAME,
        @ActionTable SYSNAME,
        @ActionIndex SYSNAME,
        @FragmentationPercent DECIMAL(10,2),
        @PageCount BIGINT,
        @MaintenanceCommand NVARCHAR(MAX),
        @ExecutableSQL NVARCHAR(MAX),
        @StartTime DATETIME2,
        @EndTime DATETIME2;

    DECLARE maintenance_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        ID,
        DatabaseName,
        SchemaName,
        TableName,
        IndexName,
        FragmentationPercent,
        PageCount,
        MaintenanceCommand
    FROM #IndexFragmentationReport
    WHERE ActionRequired = 'REBUILD'
    ORDER BY
        FragmentationPercent DESC,
        PageCount DESC;

    OPEN maintenance_cursor;

    FETCH NEXT FROM maintenance_cursor
    INTO
        @ID,
        @ActionDatabase,
        @ActionSchema,
        @ActionTable,
        @ActionIndex,
        @FragmentationPercent,
        @PageCount,
        @MaintenanceCommand;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @StartTime = SYSDATETIME();

        BEGIN TRY
            SET @ExecutableSQL =
                N'USE ' + QUOTENAME(@ActionDatabase) + N'; ' + @MaintenanceCommand;

            EXEC sys.sp_executesql @ExecutableSQL;

            SET @EndTime = SYSDATETIME();

            INSERT INTO #MaintenanceLog
            (
                DatabaseName,
                SchemaName,
                TableName,
                IndexName,
                FragmentationPercent,
                PageCount,
                MaintenanceCommand,
                ExecutionStatus,
                ErrorMessage,
                StartTime,
                EndTime
            )
            VALUES
            (
                @ActionDatabase,
                @ActionSchema,
                @ActionTable,
                @ActionIndex,
                @FragmentationPercent,
                @PageCount,
                @ExecutableSQL,
                'SUCCESS',
                NULL,
                @StartTime,
                @EndTime
            );
        END TRY
        BEGIN CATCH
            SET @EndTime = SYSDATETIME();

            INSERT INTO #MaintenanceLog
            (
                DatabaseName,
                SchemaName,
                TableName,
                IndexName,
                FragmentationPercent,
                PageCount,
                MaintenanceCommand,
                ExecutionStatus,
                ErrorMessage,
                StartTime,
                EndTime
            )
            VALUES
            (
                @ActionDatabase,
                @ActionSchema,
                @ActionTable,
                @ActionIndex,
                @FragmentationPercent,
                @PageCount,
                ISNULL(@ExecutableSQL, @MaintenanceCommand),
                'FAILED',
                ERROR_MESSAGE(),
                @StartTime,
                @EndTime
            );
        END CATCH;

        FETCH NEXT FROM maintenance_cursor
        INTO
            @ID,
            @ActionDatabase,
            @ActionSchema,
            @ActionTable,
            @ActionIndex,
            @FragmentationPercent,
            @PageCount,
            @MaintenanceCommand;
    END

    CLOSE maintenance_cursor;
    DEALLOCATE maintenance_cursor;
END
ELSE
BEGIN
    INSERT INTO #MaintenanceLog
    (
        DatabaseName,
        SchemaName,
        TableName,
        IndexName,
        FragmentationPercent,
        PageCount,
        MaintenanceCommand,
        ExecutionStatus,
        ErrorMessage,
        StartTime,
        EndTime
    )
    SELECT
        DatabaseName,
        SchemaName,
        TableName,
        IndexName,
        FragmentationPercent,
        PageCount,
        MaintenanceCommand,
        'DRY_RUN_ONLY',
        'No rebuild performed because @ExecuteMaintenance = 0.',
        NULL,
        NULL
    FROM #IndexFragmentationReport
    WHERE ActionRequired = 'REBUILD';
END

-------------------------------------------------------------------------------
-- DISPLAY MAINTENANCE LOG
-------------------------------------------------------------------------------

SELECT
    DatabaseName,
    SchemaName,
    TableName,
    IndexName,
    FragmentationPercent,
    PageCount,
    ExecutionStatus,
    ErrorMessage,
    StartTime,
    EndTime,
    MaintenanceCommand
FROM #MaintenanceLog
ORDER BY
    LogID;

-------------------------------------------------------------------------------
-- SUMMARY
-------------------------------------------------------------------------------

SELECT
    COUNT(*) AS TotalIndexesScanned,
    SUM(CASE WHEN ActionRequired = 'REBUILD' THEN 1 ELSE 0 END) AS IndexesOverThreshold,
    @FragmentationThreshold AS FragmentationThresholdUsed,
    @MinimumPageCount AS MinimumPageCountUsed,
    @ScanMode AS ScanModeUsed,
    @ExecuteMaintenance AS ExecuteMaintenanceSetting
FROM #IndexFragmentationReport;