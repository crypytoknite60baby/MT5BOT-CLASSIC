#!/usr/bin/env bash
# Register THE NEW BOT cron jobs with Hermes. Requires: hermes CLI + gateway running/installable.
set -euo pipefail

WORKDIR="/Users/samueladjaye/METATRADER 5 MQL5/THE NEW BOT"
SKILL="the-new-bot-upgrade"
DELIVER="${DELIVER:-local}"   # set DELIVER=telegram or origin to notify
# --accept-hooks is a subcommand flag on `hermes cron`, not `cron create`
CRON_ACCEPT=(--accept-hooks)

HERMES_SCRIPTS="${HOME}/.hermes/scripts"
mkdir -p "${HERMES_SCRIPTS}"
cp "${WORKDIR}/scripts/newbot-health-check.py" "${HERMES_SCRIPTS}/newbot-health-check.py"
chmod +x "${HERMES_SCRIPTS}/newbot-health-check.py"

echo "Checking Hermes gateway..."
if ! hermes gateway status 2>&1 | grep -qi running; then
  echo "WARNING: Gateway is not running. Jobs will be created but will NOT fire until:"
  echo "  hermes gateway install && hermes gateway start"
  echo ""
fi

remove_if_exists() {
  local name="$1"
  if hermes cron list 2>/dev/null | grep -q "${name}"; then
    echo "Removing existing job: ${name}"
    hermes cron remove "${name}" 2>/dev/null || true
  fi
}

remove_if_exists "newbot-daily-health"
remove_if_exists "newbot-weekly-upgrade"
remove_if_exists "newbot-biweekly-ml"
remove_if_exists "newbot-monthly-review"

echo "Creating newbot-daily-health (weeknights 22:00, no-agent)..."
hermes cron "${CRON_ACCEPT[@]}" create "0 22 * * 1-5" \
  --name "newbot-daily-health" \
  --script "newbot-health-check.py" \
  --no-agent \
  --deliver "${DELIVER}"

PROMPT_WEEKLY='Run Mode B (the-new-bot-upgrade): current backlog item on WEMADEIT_dev.mq5 only; run scripts/health_check.py; update METRICS.md, CHANGELOG, state/last_run.json; post run report.'
PROMPT_ML='Run Mode C: backup regime_classifier.onnx, run train_regime_model.py, update last_run.json; remind user to copy ONNX to MT5 Files.'
PROMPT_MONTHLY='Run Mode D: diff new_strategy vs WEMADEIT; note backtest matrix in METRICS.md; at most one ProfitMaximizer item if Phase B pending; update last_run.json.'

echo "Creating newbot-weekly-upgrade (Sunday 10:00)..."
hermes cron "${CRON_ACCEPT[@]}" create "0 10 * * 0" "${PROMPT_WEEKLY}" \
  --name "newbot-weekly-upgrade" \
  --workdir "${WORKDIR}" \
  --skill "${SKILL}" \
  --deliver "${DELIVER}"

echo "Creating newbot-biweekly-ml (1st and 15th 11:00)..."
hermes cron "${CRON_ACCEPT[@]}" create "0 11 1,15 * *" "${PROMPT_ML}" \
  --name "newbot-biweekly-ml" \
  --workdir "${WORKDIR}" \
  --skill "${SKILL}" \
  --deliver "${DELIVER}"

echo "Creating newbot-monthly-review (1st of month 09:00)..."
hermes cron "${CRON_ACCEPT[@]}" create "0 9 1 * *" "${PROMPT_MONTHLY}" \
  --name "newbot-monthly-review" \
  --workdir "${WORKDIR}" \
  --skill "${SKILL}" \
  --deliver "${DELIVER}"

echo ""
hermes cron list
echo ""
echo "Done. Ensure gateway is running: hermes gateway install && hermes gateway start"
echo "Test: hermes cron run newbot-daily-health"
