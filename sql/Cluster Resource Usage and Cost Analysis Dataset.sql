--cluster usage
 
WITH
 
-- Time-aware USD pricing
sku_prices AS (
  SELECT
    sku_name,
    price_start_time,
    COALESCE(price_end_time, TIMESTAMP'9999-12-31') AS price_end_time,
    pricing.default AS price_per_dbu
  FROM system.billing.list_prices
  WHERE currency_code = 'USD'
),
 
-- Row-level usage with USD cost
cluster_usage AS (
  SELECT
    u.workspace_id,
    COALESCE(u.usage_metadata.cluster_id,
             u.usage_metadata.warehouse_id)             AS resource_id,
    CASE
      WHEN u.usage_metadata.cluster_id   IS NOT NULL THEN 'CLUSTER'
      WHEN u.usage_metadata.warehouse_id IS NOT NULL THEN 'SQL_WAREHOUSE'
      ELSE 'SERVERLESS'
    END                                                AS resource_type,
    u.sku_name,
    u.custom_tags['team']                              AS team,
    u.usage_start_time,
    u.usage_end_time,
    u.usage_quantity                                   AS dbus,
    u.usage_quantity * COALESCE(sp.price_per_dbu, 0)   AS cost_usd
  FROM system.billing.usage u
  LEFT JOIN sku_prices sp
    ON  u.sku_name = sp.sku_name
    AND u.usage_start_time >= sp.price_start_time
    AND u.usage_start_time <  sp.price_end_time
  -- Optional time filter:
  -- WHERE u.usage_start_time >= CURRENT_TIMESTAMP() - INTERVAL 30 DAYS
),
 
-- CPU / memory utilization from node-level telemetry
node_util AS (
  SELECT
    workspace_id,
    cluster_id,
    AVG(cpu_user_percent + cpu_system_percent) AS avg_cpu_pct,
    MAX(cpu_user_percent + cpu_system_percent) AS peak_cpu_pct,
    AVG(mem_used_percent)                      AS avg_mem_pct,
    MAX(mem_used_percent)                      AS peak_mem_pct,
    COUNT(*)                                   AS node_samples
  FROM system.compute.node_timeline
  GROUP BY workspace_id, cluster_id
),
 
-- Roll up usage to one row per cluster
cluster_rollup AS (
  SELECT
    cu.workspace_id,
    cu.resource_id,
    cu.resource_type,
    COALESCE(c.cluster_name, cu.resource_id) AS cluster_name,
    c.cluster_source                          AS cluster_source,   -- JOB / UI / API / DLT
    c.owned_by                                AS cluster_owner,
    c.worker_node_type,
    c.driver_node_type,
    c.min_autoscale_workers,
    c.max_autoscale_workers,
    MAX_BY(cu.sku_name, cu.dbus)              AS primary_sku,
    ANY_VALUE(cu.team)                        AS team,
    MIN(cu.usage_start_time)                  AS first_used_at,
    MAX(cu.usage_end_time)                    AS last_used_at,
    ROUND(SUM(TIMESTAMPDIFF(SECOND, cu.usage_start_time, cu.usage_end_time))/3600.0, 2)
                                              AS total_uptime_hours,
    ROUND(SUM(cu.dbus), 4)                    AS total_dbus,
    ROUND(SUM(cu.cost_usd), 2)                AS total_cost_usd
  FROM cluster_usage cu
  LEFT JOIN system.compute.clusters c
    ON  cu.resource_id  = c.cluster_id
    AND cu.workspace_id = c.workspace_id
  GROUP BY
    cu.workspace_id, cu.resource_id, cu.resource_type,
    c.cluster_name, c.cluster_source, c.owned_by,
    c.worker_node_type, c.driver_node_type,
    c.min_autoscale_workers, c.max_autoscale_workers
)
 
SELECT
  cr.cluster_name,
  cr.resource_id                                                AS cluster_id,
  cr.resource_type,                                             -- CLUSTER / SQL_WAREHOUSE / SERVERLESS
  cr.cluster_source,
  cr.primary_sku,
  cr.cluster_owner,
  cr.team,
  cr.worker_node_type,
  cr.min_autoscale_workers,
  cr.max_autoscale_workers,
 
  -- Volume & spend
  cr.total_uptime_hours,
  cr.total_dbus,
  cr.total_cost_usd,
 
  -- Effective economics (these are the "utilized" rates you asked for)
  ROUND(cr.total_cost_usd / NULLIF(cr.total_uptime_hours, 0), 2) AS cost_per_hour_usd,
  ROUND(cr.total_cost_usd / NULLIF(cr.total_dbus, 0), 4)         AS effective_price_per_dbu_usd,
  ROUND(cr.total_dbus    / NULLIF(cr.total_uptime_hours, 0), 4)  AS dbus_per_hour,
 
  -- Node-level utilization (from compute.node_timeline)
  ROUND(nu.avg_cpu_pct, 1)                                      AS avg_cpu_pct,
  ROUND(nu.peak_cpu_pct, 1)                                     AS peak_cpu_pct,
  ROUND(nu.avg_mem_pct, 1)                                      AS avg_mem_pct,
  ROUND(nu.peak_mem_pct, 1)                                     AS peak_mem_pct,
 
  -- Optimization flag
  CASE
    WHEN nu.avg_cpu_pct IS NULL                       THEN 'NO_TELEMETRY (serverless/short)'
    WHEN nu.avg_cpu_pct < 20 AND nu.avg_mem_pct < 30  THEN 'UNDER_UTILIZED — rightsize down'
    WHEN nu.peak_cpu_pct > 90 OR  nu.peak_mem_pct > 90 THEN 'OVER_UTILIZED — rightsize up / raise autoscale'
    WHEN nu.avg_cpu_pct BETWEEN 40 AND 75             THEN 'WELL_UTILIZED'
    ELSE 'NORMAL'
  END                                                           AS utilization_flag,
 
  cr.first_used_at,
  cr.last_used_at
FROM cluster_rollup cr
LEFT JOIN node_util nu
  ON  cr.workspace_id = nu.workspace_id
  AND cr.resource_id  = nu.cluster_id
ORDER BY cr.total_cost_usd DESC NULLS LAST;
 
 