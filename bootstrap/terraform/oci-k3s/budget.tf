variable "budget_alert_email" {
  description = "Email address notified on any OCI spend (free-tier tripwire)."
  type        = string
  default     = "me@tuckermclean.com"
}

resource "oci_budget_budget" "free_tier_guard" {
  compartment_id = var.tenancy_ocid # budgets are created at the tenancy root
  amount         = 1                # whole dollars only (OCI requires an integer)
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid] # entire tenancy — catch spend anywhere
  display_name   = "free-tier-guard"
  description    = "Free-tier spend tripwire. Expected spend is $0 on always-free; any charge means Oracle changed something."
}

resource "oci_budget_alert_rule" "actual_first_cent" {
  budget_id      = oci_budget_budget.free_tier_guard.id
  type           = "ACTUAL"
  threshold_type = "PERCENTAGE"
  threshold      = 1 # 1% of $1 = $0.01 — fires on the first real cent of spend
  recipients     = var.budget_alert_email
  display_name   = "actual-any-spend"
  message        = "OCI ACTUAL spend crossed ~$0.01 — you are being charged. Investigate immediately."
}

resource "oci_budget_alert_rule" "forecast_over_budget" {
  budget_id      = oci_budget_budget.free_tier_guard.id
  type           = "FORECAST"
  threshold_type = "PERCENTAGE"
  threshold      = 100 # forecast to reach 100% of the $1 budget
  recipients     = var.budget_alert_email
  display_name   = "forecast-over-1-dollar"
  message        = "OCI is forecast to exceed $1 this month. A charge is coming — check usage."
}
