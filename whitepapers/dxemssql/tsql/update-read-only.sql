USE [master] 
GO 
--Only allow read-write connections in the primary role
ALTER AVAILABILITY GROUP AGS1 MODIFY REPLICA ON N'dxemssql-3' WITH (
    PRIMARY_ROLE (ALLOW_CONNECTIONS = READ_WRITE)
)
GO
--Allow read-only connections in the secondary role
ALTER AVAILABILITY GROUP AGS1 MODIFY REPLICA ON N'dxemssql-3' WITH (
    SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)
)
GO