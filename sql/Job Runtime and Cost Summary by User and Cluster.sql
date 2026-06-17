--job usage
SELECT
  u.identity_metadata.run_as AS Username,
  u.workspace_id,
  u.usage_metadata.job_id AS job_id,
  j.name AS job_name,
  j.run_as_user_name AS run_as_user_name,
  u.sku_name,
  u.usage_date,
  u.usage_metadata.cluster_id AS cluster_id,
  COALESCE(MAX(jr.total_runtime_minutes), 0) AS total_runtime_minutes,
  SUM(u.usage_quantity * COALESCE(sp.pricing.default, 0)) AS cost_usd
FROM
  system.billing.usage u
LEFT JOIN system.billing.list_prices sp
  ON u.sku_name = sp.sku_name
LEFT JOIN system.lakeflow.jobs j
  ON u.usage_metadata.job_id = j.job_id
LEFT JOIN system.compute.clusters c
ON u.usage_metadata.cluster_id = c.cluster_id
LEFT JOIN (
  SELECT
    workspace_id,
    job_id,
    CAST(period_start_time AS DATE) AS usage_date,
    ROUND(SUM(TIMESTAMPDIFF(SECOND, period_start_time, period_end_time)) / 60.0, 2) AS total_runtime_minutes
    -- SUM(TIMESTAMPDIFF(MINUTE, period_start_time, period_end_time)) AS total_runtime_minutes
  FROM system.lakeflow.job_run_timeline
  GROUP BY workspace_id, job_id, CAST(period_start_time AS DATE)
) jr 
 ON u.workspace_id = jr.workspace_id 
 AND u.usage_metadata.job_id = jr.job_id 
 AND u.usage_date = jr.usage_date
WHERE
  sp.currency_code = 'USD'
GROUP BY
  u.identity_metadata.run_as,
  u.workspace_id,
  u.usage_metadata.job_id,
  j.name,
  u.usage_metadata.cluster_id,
  j.run_as_user_name,
  u.sku_name,
  u.usage_date
ORDER BY
  cost_usd DESC;
 
-- select * from system.compute.clusters
 