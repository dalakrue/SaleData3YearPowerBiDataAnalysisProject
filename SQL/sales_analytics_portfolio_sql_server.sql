/*
    Sales Analytics Portfolio — SQL Server 2022+
    Skills demonstrated:
      - typed staging table and bulk-load pattern
      - reusable analytical view
      - data-quality tests and safe-grain decisions
      - CTEs, conditional aggregation, window functions, Pareto analysis
      - anomaly detection, indexing, and a parameterized stored procedure

    Metric definitions
      SalesValue   = SoldQty * SalePrice
      PurchaseCost = SoldQty * Price
      GrossProfit  = SalesValue - PurchaseCost

    Important quality warning
      OrderID is not a reliable unique order key in this file. Use one source row
      as one SalesRecord unless a corrected order key is supplied.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('dbo.SalesRaw', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SalesRaw
    (
        SalesRecordKey BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_SalesRaw PRIMARY KEY,
        OrderID        INT            NOT NULL,
        OrderDate      DATE           NOT NULL,
        CustomerID     VARCHAR(30)    NOT NULL,
        ProductName    VARCHAR(100)   NOT NULL,
        SoldQty        INT            NOT NULL,
        Price          DECIMAL(12,2)  NOT NULL,
        Gender         VARCHAR(20)    NOT NULL,
        Region         VARCHAR(50)    NOT NULL,
        TSP            VARCHAR(50)    NOT NULL,
        Age            INT            NOT NULL,
        SalePrice      DECIMAL(12,2)  NOT NULL,
        Category       VARCHAR(50)    NOT NULL,
        CustomerName   VARCHAR(150)   NOT NULL,
        CONSTRAINT CK_SalesRaw_SoldQty CHECK (SoldQty > 0),
        CONSTRAINT CK_SalesRaw_Prices CHECK (Price >= 0 AND SalePrice >= 0),
        CONSTRAINT CK_SalesRaw_Age CHECK (Age BETWEEN 0 AND 120)
    );
END;
GO

/*
    Load example (edit the absolute path for the SQL Server host):

    BULK INSERT dbo.SalesRaw
    FROM 'C:\\portfolio\\sales_data_3_years.csv'
    WITH
    (
        FORMAT = 'CSV',
        FIRSTROW = 2,
        FIELDQUOTE = '"',
        ROWTERMINATOR = '0x0a',
        TABLOCK
    );
*/

CREATE OR ALTER VIEW dbo.vw_SalesEnriched
AS
SELECT
    s.SalesRecordKey,
    s.OrderID,
    s.OrderDate,
    DATEFROMPARTS(YEAR(s.OrderDate), MONTH(s.OrderDate), 1) AS MonthStart,
    YEAR(s.OrderDate) AS SalesYear,
    DATEPART(QUARTER, s.OrderDate) AS SalesQuarter,
    s.CustomerID,
    s.CustomerName,
    s.ProductName,
    s.Category,
    s.Region,
    s.TSP AS Branch,
    s.Gender,
    s.Age,
    CASE
        WHEN s.Age < 30 THEN '18-29'
        WHEN s.Age < 45 THEN '30-44'
        WHEN s.Age < 60 THEN '45-59'
        ELSE '60+'
    END AS AgeBand,
    s.SoldQty,
    s.Price,
    s.SalePrice,
    CAST(s.SoldQty * s.SalePrice AS DECIMAL(19,2)) AS SalesValue,
    CAST(s.SoldQty * s.Price AS DECIMAL(19,2)) AS PurchaseCost,
    CAST(s.SoldQty * (s.SalePrice - s.Price) AS DECIMAL(19,2)) AS GrossProfit,
    CAST(
        CASE WHEN s.SalePrice = 0 THEN NULL
             ELSE (s.SalePrice - s.Price) / s.SalePrice
        END AS DECIMAL(9,4)
    ) AS GrossMargin
FROM dbo.SalesRaw AS s;
GO

/* 1) DATA-QUALITY SCORECARD */
SELECT
    COUNT_BIG(*) AS SalesRecords,
    COUNT(DISTINCT OrderID) AS DistinctOrderIDs,
    COUNT(DISTINCT CustomerID) AS DistinctCustomerIDs,
    MIN(OrderDate) AS FirstOrderDate,
    MAX(OrderDate) AS LastOrderDate,
    SUM(CASE WHEN CustomerID = '' OR ProductName = '' OR Region = '' THEN 1 ELSE 0 END)
        AS BlankRequiredTextRows,
    SUM(CASE WHEN SalePrice <> 2 * Price THEN 1 ELSE 0 END)
        AS RowsWhereSalePriceIsNotExactlyTwiceCost
FROM dbo.SalesRaw;
GO

/* Repeated OrderIDs that conflict across dates/customers are not genuine line items. */
WITH OrderIDProfile AS
(
    SELECT
        OrderID,
        COUNT_BIG(*) AS RowCount,
        COUNT(DISTINCT OrderDate) AS DistinctDates,
        COUNT(DISTINCT CustomerID) AS DistinctCustomers,
        COUNT(DISTINCT Region) AS DistinctRegions,
        COUNT(DISTINCT ProductName) AS DistinctProducts
    FROM dbo.SalesRaw
    GROUP BY OrderID
)
SELECT
    COUNT_BIG(*) AS DuplicatedOrderIDs,
    SUM(RowCount - 1) AS ExtraRowsOnDuplicatedIDs,
    SUM(CASE WHEN DistinctDates > 1 THEN 1 ELSE 0 END) AS IDsAcrossDates,
    SUM(CASE WHEN DistinctCustomers > 1 THEN 1 ELSE 0 END) AS IDsAcrossCustomers,
    MAX(RowCount) AS MaximumRowsPerOrderID
FROM OrderIDProfile
WHERE RowCount > 1;
GO

/* 2) EXECUTIVE KPI SUMMARY — record grain is explicit. */
SELECT
    COUNT_BIG(*) AS SalesRecords,
    SUM(SoldQty) AS UnitsSold,
    CAST(SUM(SalesValue) AS DECIMAL(19,2)) AS SalesValue,
    CAST(SUM(PurchaseCost) AS DECIMAL(19,2)) AS PurchaseCost,
    CAST(SUM(GrossProfit) AS DECIMAL(19,2)) AS GrossProfit,
    CAST(SUM(GrossProfit) / NULLIF(SUM(SalesValue), 0) AS DECIMAL(9,4)) AS GrossMargin,
    CAST(AVG(SalesValue) AS DECIMAL(19,2)) AS AverageSalesRecordValue
FROM dbo.vw_SalesEnriched;
GO

/* 3) MONTHLY TREND WITH MoM AND YoY WINDOW COMPARISONS. */
WITH Monthly AS
(
    SELECT
        MonthStart,
        SUM(SalesValue) AS SalesValue,
        SUM(GrossProfit) AS GrossProfit,
        SUM(SoldQty) AS UnitsSold,
        COUNT_BIG(*) AS SalesRecords
    FROM dbo.vw_SalesEnriched
    GROUP BY MonthStart
),
Trend AS
(
    SELECT
        m.*,
        LAG(SalesValue, 1) OVER (ORDER BY MonthStart) AS PreviousMonthSales,
        LAG(SalesValue, 12) OVER (ORDER BY MonthStart) AS PreviousYearSales,
        AVG(SalesValue) OVER
        (
            ORDER BY MonthStart
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS ThreeMonthMovingAverage
    FROM Monthly AS m
)
SELECT
    MonthStart,
    CAST(SalesValue AS DECIMAL(19,2)) AS SalesValue,
    CAST(GrossProfit AS DECIMAL(19,2)) AS GrossProfit,
    UnitsSold,
    SalesRecords,
    CAST((SalesValue - PreviousMonthSales) / NULLIF(PreviousMonthSales, 0) AS DECIMAL(9,4)) AS MoMGrowth,
    CAST((SalesValue - PreviousYearSales) / NULLIF(PreviousYearSales, 0) AS DECIMAL(9,4)) AS YoYGrowth,
    CAST(ThreeMonthMovingAverage AS DECIMAL(19,2)) AS SalesValue3MMA
FROM Trend
ORDER BY MonthStart;
GO

/* 4) PRODUCT PARETO — rank, contribution, and cumulative contribution. */
WITH ProductSales AS
(
    SELECT
        ProductName,
        SUM(SalesValue) AS SalesValue,
        SUM(GrossProfit) AS GrossProfit,
        SUM(SoldQty) AS UnitsSold
    FROM dbo.vw_SalesEnriched
    GROUP BY ProductName
),
Ranked AS
(
    SELECT
        p.*,
        DENSE_RANK() OVER (ORDER BY SalesValue DESC) AS SalesRank,
        SalesValue / NULLIF(SUM(SalesValue) OVER (), 0) AS SalesShare,
        UnitsSold * 1.0 / NULLIF(SUM(UnitsSold) OVER (), 0) AS UnitShare,
        SUM(SalesValue) OVER
        (
            ORDER BY SalesValue DESC, ProductName
            ROWS UNBOUNDED PRECEDING
        ) / NULLIF(SUM(SalesValue) OVER (), 0) AS CumulativeSalesShare
    FROM ProductSales AS p
)
SELECT
    ProductName,
    SalesRank,
    CAST(SalesValue AS DECIMAL(19,2)) AS SalesValue,
    CAST(GrossProfit AS DECIMAL(19,2)) AS GrossProfit,
    UnitsSold,
    CAST(SalesShare AS DECIMAL(9,4)) AS SalesShare,
    CAST(UnitShare AS DECIMAL(9,4)) AS UnitShare,
    CAST(CumulativeSalesShare AS DECIMAL(9,4)) AS CumulativeSalesShare,
    CASE WHEN CumulativeSalesShare <= 0.80 THEN 'Core 80%'
         ELSE 'Long tail'
    END AS ParetoClass
FROM Ranked
ORDER BY SalesRank, ProductName;
GO

/* 5) REGION × PRODUCT OPPORTUNITY MATRIX WITH WITHIN-REGION RANK. */
WITH RegionProduct AS
(
    SELECT
        Region,
        ProductName,
        SUM(SalesValue) AS SalesValue,
        SUM(SoldQty) AS UnitsSold,
        COUNT_BIG(*) AS SalesRecords
    FROM dbo.vw_SalesEnriched
    GROUP BY Region, ProductName
)
SELECT
    Region,
    ProductName,
    CAST(SalesValue AS DECIMAL(19,2)) AS SalesValue,
    UnitsSold,
    SalesRecords,
    DENSE_RANK() OVER (PARTITION BY Region ORDER BY SalesValue DESC) AS ProductRankInRegion,
    CAST(
        SalesValue / NULLIF(SUM(SalesValue) OVER (PARTITION BY Region), 0)
        AS DECIMAL(9,4)
    ) AS RegionSalesShare
FROM RegionProduct
ORDER BY Region, ProductRankInRegion, ProductName;
GO

/* 6) CONDITIONAL AGGREGATION FOR A COMPACT REGIONAL SCORECARD. */
SELECT
    Region,
    SUM(CASE WHEN ProductName = 'Apple' THEN SalesValue ELSE 0 END) AS AppleSales,
    SUM(CASE WHEN ProductName = 'Durian' THEN SalesValue ELSE 0 END) AS DurianSales,
    SUM(CASE WHEN ProductName = 'Grapes' THEN SalesValue ELSE 0 END) AS GrapesSales,
    SUM(CASE WHEN ProductName = 'Mango' THEN SalesValue ELSE 0 END) AS MangoSales,
    SUM(CASE WHEN ProductName = 'Orange' THEN SalesValue ELSE 0 END) AS OrangeSales,
    SUM(SalesValue) AS TotalSalesValue
FROM dbo.vw_SalesEnriched
GROUP BY Region
ORDER BY TotalSalesValue DESC;
GO

/* 7) DAILY ANOMALY SCREEN USING A Z-SCORE. Investigate; do not call this causality. */
WITH Daily AS
(
    SELECT OrderDate, SUM(SalesValue) AS SalesValue, COUNT_BIG(*) AS SalesRecords
    FROM dbo.vw_SalesEnriched
    GROUP BY OrderDate
),
Scored AS
(
    SELECT
        d.*,
        AVG(SalesValue) OVER () AS MeanDailySales,
        STDEV(SalesValue) OVER () AS StdDevDailySales
    FROM Daily AS d
)
SELECT TOP (20)
    OrderDate,
    CAST(SalesValue AS DECIMAL(19,2)) AS SalesValue,
    SalesRecords,
    CAST((SalesValue - MeanDailySales) / NULLIF(StdDevDailySales, 0) AS DECIMAL(9,3)) AS ZScore
FROM Scored
ORDER BY ABS((SalesValue - MeanDailySales) / NULLIF(StdDevDailySales, 0)) DESC;
GO

/* 8) INDEXES ALIGNED TO THE DASHBOARD FILTER AND GROUPING PATHS. */
IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.SalesRaw')
      AND name = 'IX_SalesRaw_OrderDate_Region_Product'
)
BEGIN
    CREATE INDEX IX_SalesRaw_OrderDate_Region_Product
        ON dbo.SalesRaw (OrderDate, Region, ProductName)
        INCLUDE (SoldQty, Price, SalePrice, Category, TSP);
END;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.SalesRaw')
      AND name = 'IX_SalesRaw_OrderID'
)
BEGIN
    CREATE INDEX IX_SalesRaw_OrderID
        ON dbo.SalesRaw (OrderID)
        INCLUDE (OrderDate, CustomerID, Region, ProductName);
END;
GO

/* 9) PARAMETERIZED PROCEDURE FOR POWER BI DIRECTQUERY OR INTERVIEW DEMO. */
CREATE OR ALTER PROCEDURE dbo.usp_SalesPerformance
    @StartDate DATE,
    @EndDate   DATE,
    @Region    VARCHAR(50) = NULL,
    @Product   VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @EndDate < @StartDate
        THROW 50001, 'End date must be on or after start date.', 1;

    SELECT
        MonthStart,
        Region,
        ProductName,
        SUM(SalesValue) AS SalesValue,
        SUM(GrossProfit) AS GrossProfit,
        SUM(SoldQty) AS UnitsSold,
        COUNT_BIG(*) AS SalesRecords
    FROM dbo.vw_SalesEnriched
    WHERE OrderDate >= @StartDate
      AND OrderDate <= @EndDate
      AND (@Region IS NULL OR Region = @Region)
      AND (@Product IS NULL OR ProductName = @Product)
    GROUP BY MonthStart, Region, ProductName
    ORDER BY MonthStart, Region, ProductName;
END;
GO

/* Example interview demo call:
   EXEC dbo.usp_SalesPerformance
        @StartDate = '2023-01-01',
        @EndDate   = '2023-12-30',
        @Region    = 'Bago',
        @Product   = 'Orange';
*/
