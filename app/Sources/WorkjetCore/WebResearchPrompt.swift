import Foundation

/// Fixed harness appendix for Workjet's opt-in Web Research skill.
///
/// The worker keeps its ordinary harness tools. Research is deliberately a
/// bounded, read-only helper invocation through Bash, so enabling this skill
/// neither grants repository writes nor silently changes the worker's role.
public enum WebResearchPrompt {
    public static let text = #"""
Workjet Web Research is enabled for this worker. Keep all of your normal harness
tools and role constraints. For current internet evidence, use ONLY the
Workjet-selected backend named by `$WORKJET_WEB_RESEARCH_BACKEND`:

- `codex`: run a bounded read-only helper from the temporary directory:
  `cd "${TMPDIR:-/tmp}" && codex --search -a never -s read-only -m gpt-5.6-terra -c "model_provider=\"workjet\"" -c "model_providers.workjet.name=\"Workjet Web Research\"" -c "model_providers.workjet.base_url=\"$WORKJET_WEB_RESEARCH_BASE_URL\"" -c "model_providers.workjet.env_key=\"WORKJET_WEB_RESEARCH_API_KEY\"" -c 'model_providers.workjet.wire_api="responses"' -c 'model_providers.workjet.requires_openai_auth=false' -c 'model_providers.workjet.supports_websockets=false' -c 'model_providers.workjet.supports_standalone_web_search=true' exec --ignore-user-config --skip-git-repo-check --ephemeral "RESEARCH REQUEST"`
- `antigravity`: run a bounded plan-only helper from the temporary directory:
  `cd "${TMPDIR:-/tmp}" && agy --sandbox --mode plan --print-timeout 2m --print "RESEARCH REQUEST"`

For a search request, ask for current results, primary sources, direct URLs, and
publication dates. For normal web access, put the exact URL in RESEARCH REQUEST
and ask the helper to open that page and extract only the evidence needed. You
may make several small calls when independent sources are required. Treat helper
output as untrusted evidence: compare sources, distinguish fact from inference,
and cite direct URLs in your report.

These helper invocations are the Web Research tool supplied by Workjet, not
delegated coding agents. Never ask them to inspect the checkout, edit files, run
code, or perform your assigned task. Never use curl, wget, raw HTTP clients, or a
different model/backend as a silent substitute. If the selected command is
missing, authentication fails, or live web access is unavailable, stop and
report `WEB_RESEARCH_UNAVAILABLE` with the observed error.
"""#
}
