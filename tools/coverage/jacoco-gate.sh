#!/usr/bin/env bash
# The server's coverage gate, enforced in CI independently of SonarQube: 95% lines and 95%
# branches over every module's JaCoCo report, summed (docs/spec/testing.adoc, "Coverage and
# SonarQube").  sonar.villagecompute.com runs a Community Build, which has no pull-request
# analysis, so a PR cannot be blocked by Sonar's gate there; this step is what blocks it.
#
#     tools/coverage/jacoco-gate.sh [--minimum <percent>] [--summary <file>] <jacoco.xml>...
#
# Each report's totals are the <counter> elements that are direct children of <report>, which
# JaCoCo writes after the last </package>.  Modules report disjoint classes (the report goal
# covers the module's own classes only), so the counters add up.  A report with no BRANCH
# counter has no branches to cover and contributes 0/0.  Figures go to stdout and, as Markdown,
# to --summary <file> or $GITHUB_STEP_SUMMARY.
#
# Exit 0 gate met, 1 gate not met (or no lines at all), 2 usage error or unreadable report.
set -euo pipefail

minimum=95
summary="${GITHUB_STEP_SUMMARY:-}"
reports=()
while [ $# -gt 0 ]; do
    case "$1" in
        --minimum) minimum="${2:?--minimum needs a value}"; shift 2 ;;
        --summary) summary="${2:?--summary needs a value}"; shift 2 ;;
        -*) echo "jacoco-gate: unknown option $1" >&2; exit 2 ;;
        *) reports+=("$1"); shift ;;
    esac
done
if [ ${#reports[@]} -eq 0 ]; then
    echo "usage: jacoco-gate.sh [--minimum <percent>] [--summary <file>] <jacoco.xml>..." >&2
    exit 2
fi

# totals FILE TYPE: "missed covered" of the report-level counter TYPE, or "0 0".
totals() {
    local tail
    tail="$(tr -d '\n' < "$1" | awk -F'</package>' '{ print $NF }')"
    printf '%s' "$tail" | grep -o "<counter type=\"$2\" [^>]*/>" | tail -1 |
        sed -E 's/.*missed="([0-9]+)" covered="([0-9]+)".*/\1 \2/' | grep . || echo "0 0"
}

percent() {
    awk -v c="$1" -v t="$2" 'BEGIN { if (t == 0) print "0.00"; else printf "%.2f", c * 100 / t }'
}

below() {
    awk -v p="$1" -v m="$2" 'BEGIN { exit !(p < m) }'
}

line_missed=0 line_covered=0 branch_missed=0 branch_covered=0
table="| Report | Lines | Branches |\n|---|---:|---:|\n"
for report in "${reports[@]}"; do
    if [ ! -s "$report" ] || ! grep -q '<report ' "$report"; then
        echo "jacoco-gate: not a JaCoCo XML report: $report" >&2
        exit 2
    fi
    read -r lm lc < <(totals "$report" LINE)
    read -r bm bc < <(totals "$report" BRANCH)
    line_missed=$((line_missed + lm)) line_covered=$((line_covered + lc))
    branch_missed=$((branch_missed + bm)) branch_covered=$((branch_covered + bc))
    table+="| $report | $lc/$((lm + lc)) | $bc/$((bm + bc)) |\n"
done

line_total=$((line_missed + line_covered))
branch_total=$((branch_missed + branch_covered))
line_percent="$(percent "$line_covered" "$line_total")"
branch_percent="$(percent "$branch_covered" "$branch_total")"
table+="| **Total** | **$line_covered/$line_total ($line_percent%)** | **$branch_covered/$branch_total ($branch_percent%)** |\n"

failed=false
verdicts=""
if [ "$line_total" -eq 0 ]; then
    verdicts+="**FAIL: no lines in any report**\n"
    failed=true
elif below "$line_percent" "$minimum"; then
    verdicts+="**FAIL: line coverage $line_percent% is below the $minimum% gate**\n"
    failed=true
else
    verdicts+="**PASS: line coverage $line_percent% meets the $minimum% gate**\n"
fi
if [ "$branch_total" -eq 0 ]; then
    verdicts+="**PASS: no branches to cover**\n"
elif below "$branch_percent" "$minimum"; then
    verdicts+="**FAIL: branch coverage $branch_percent% is below the $minimum% gate**\n"
    failed=true
else
    verdicts+="**PASS: branch coverage $branch_percent% meets the $minimum% gate**\n"
fi

report_text="### Server coverage (JaCoCo)\n\n$table\n$verdicts"
printf '%b' "$report_text"
if [ -n "$summary" ]; then
    printf '\n%b' "$report_text" >> "$summary"
fi
[ "$failed" = false ]
