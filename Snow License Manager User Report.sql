begin tran
INSERT INTO SnowLicenseManager.dbo.tblReport (StockReport, IsCustomReport, ReportType, ViewName, Name, Description, SQLQuery, ColumnList, ColumnVisibility)
VALUES (0,1,3,'QUERYBUILDER','Snow License Manager System Users','Report to show user permissions and accounts for Snow License Manager [v1.4]','SELECT MAX(u.UserName) AS [UserName],
       STUFF(
               (SELECT '', '' + G.GroupName
                FROM SnowLicenseManager.dbo.tblSystemUserGroups UG
                INNER JOIN SnowLicenseManager.dbo.tblSystemGroup G ON G.GroupID = UG.GroupID
                WHERE UG.UserID = U.UserID
                  FOR XML PATH('')), 1, 1, '') [Group Name],
       MAX(g.Description) AS [Group Description],
       MAX(u.FirstName) AS [First Name],
       MAX(u.LastName) AS [Last Name],
       ISNULL(MAX(u.Email), ''N/A'') AS [Email],
       MAX(u.LogonCounter) AS [Logon Count],
       MAX(u.LogonDate) AS [Last Logon],
       DATEDIFF(DAY, MAX(u.LogonDate), GETDATE()) AS [Days Since Last Logon],
       CASE
           WHEN MAX(CONVERT(INT, u.MustChangePassword)) = 0 THEN ''NO''
           WHEN MAX(CONVERT(INT, u.MustChangePassword)) = 1 THEN ''Yes''
       END AS [Must Change Password],
       ISNULL(CASE
                  WHEN CONVERT(DATE, MAX(u.PasswordExpirationDate)) = ''1900-01-01'' THEN ''NO Expiry''
                  ELSE CONVERT(CHAR(26), MAX(u.PasswordExpirationDate), 21)
              END, ''NO Expiry'') AS [Password Expiry],
       CASE
           WHEN MAX(CONVERT(INT, u.TermsAccepted)) = 0 THEN ''NO''
           WHEN MAX(CONVERT(INT, u.TermsAccepted)) = 1 THEN ''Yes''
           ELSE ''Yes''
       END AS [Terms Accepted],
       ISNULL(CASE
                  WHEN CONVERT(DATE, MAX(u.BlockedUntil)) = ''1900-01-01'' THEN ''NOT Blocked''
                  ELSE CONVERT(CHAR(26), MAX(u.BlockedUntil), 21)
              END, ''NOT Blocked'') AS [Last Block],
       MAX(u.Language) AS [User Language],
       MAX(u.CreatedDate) AS [Created Date],
       MAX(u.UpdatedDate) AS [Updated Date],
       MAX(u.ValidTo) AS [ValidTo],
       MAX(u.ValidFrom) AS [ValidFrom]
FROM SnowLicenseManager.dbo.tblSystemUser u
INNER JOIN SnowLicenseManager.dbo.tblSystemUserGroups ug ON ug.UserID = u.UserID
INNER JOIN SnowLicenseManager.dbo.tblSystemGroup g ON ug.GroupID = g.GroupID
INNER JOIN SnowLicenseManager.dbo.tblCID c ON u.CID = c.CID
WHERE c.CID = 1
GROUP BY u.UserID;',
'Username,Group Name,First Name,Last Name,Email,Last Logon',
'1,1,1,1,1,1')

commit