#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "--force-regenerate renders a fresh scaffold before archiving" \
    "fm-brief.sh --help omitted archive-and-regenerate mechanics"
  pass "fm-brief.sh: --help renders the complete header"
}

test_ship_task_guidance_is_structured_and_proportional() {
  local home help brief out
  home="$TMP_ROOT/ship-task-guidance-home"
  out="$home/scaffold.out"
  mkdir -p "$home/data"

  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "numbered, individually testable acceptance criteria" \
    "fm-brief.sh --help omitted numbered, testable acceptance-criteria guidance"
  assert_contains "$help" "explicit non-goals list" \
    "fm-brief.sh --help omitted proportional non-goals guidance"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" ship-task-guidance sample-project >"$out" 2>&1 \
    || fail "ship brief with structured task guidance did not scaffold"
  brief="$home/data/ship-task-guidance/brief.md"
  assert_grep "numbered, individually testable acceptance criteria" "$brief" \
    "ship brief omitted numbered, testable acceptance-criteria guidance"
  assert_grep "every criterion checkable by a command, test, or observation" "$brief" \
    "ship brief omitted the acceptance-criteria verification bar"
  assert_grep "multi-slice or product-shaped features, include an explicit non-goals list" "$brief" \
    "ship brief omitted proportional non-goals guidance"
  assert_grep "github/spec-kit structure" "$brief" \
    "ship brief omitted attribution for the adapted structure"
  assert_grep "replace {TASK} with numbered, individually testable acceptance criteria" "$out" \
    "ship scaffold hint omitted the structured task guidance"
  pass "fm-brief.sh: ship task guidance is numbered, testable, and proportional"
}

test_existing_brief_refusal_detects_staleness_and_force_regenerates() {
  local home id brief err out status archive_count archive
  home="$TMP_ROOT/stale-brief-home"
  id=stale-brief-guard
  brief="$home/data/$id/brief.md"
  err="$home/refusal.err"
  out="$home/regenerate.out"
  mkdir -p "$(dirname "$brief")"
  printf '%s\n' 'months-old draft without current safety contracts' > "$brief"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj > /dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "scaffolding over an existing stale brief must fail"
  assert_grep "missing current scaffold safety marker" "$err" \
    "existing stale brief refusal did not detect its missing safety marker"
  assert_grep "Do not launch this brief unchanged" "$err" \
    "existing stale brief refusal did not prevent unchanged launch"
  assert_grep "--force-regenerate" "$err" \
    "existing stale brief refusal did not name the archive-and-regenerate recovery"
  assert_grep "months-old draft" "$brief" \
    "ordinary refusal changed the existing stale brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --force-regenerate >"$out" 2>&1 \
    || fail "--force-regenerate did not replace a stale brief safely"
  assert_grep "firstmate-brief-scaffold-safety:v1" "$brief" \
    "regenerated brief is missing the current scaffold safety marker"
  assert_grep "archived existing brief:" "$out" \
    "--force-regenerate did not report the archive path"
  archive_count=$(find "$(dirname "$brief")" -maxdepth 1 -type f -name 'brief.md.archive-*' | wc -l | tr -d ' ')
  [ "$archive_count" = 1 ] \
    || fail "--force-regenerate must create exactly one archive, found $archive_count"
  archive=$(find "$(dirname "$brief")" -maxdepth 1 -type f -name 'brief.md.archive-*' -print)
  assert_grep "months-old draft without current safety contracts" "$archive" \
    "--force-regenerate archive did not preserve the stale brief"
  pass "fm-brief.sh: stale existing briefs fail loudly and force regeneration archives before replacing"
}

test_existing_current_brief_still_requires_freshness_verification() {
  local home id brief err status
  home="$TMP_ROOT/current-brief-home"
  id=current-brief-guard
  err="$home/refusal.err"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1 \
    || fail "current brief fixture did not scaffold"
  brief="$home/data/$id/brief.md"
  assert_grep "firstmate-brief-scaffold-safety:v1" "$brief" \
    "fresh brief fixture is missing the current scaffold safety marker"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "scaffolding over an existing current brief must still fail"
  assert_grep "current scaffold safety marker is present" "$err" \
    "existing current brief refusal did not report marker status"
  assert_grep "task freshness is unverified" "$err" \
    "existing current brief refusal falsely treated its marker as freshness proof"
  assert_grep "verify it intentionally, or rerun with --force-regenerate" "$err" \
    "existing current brief refusal did not give both safe recovery choices"
  pass "fm-brief.sh: a current safety marker never substitutes for task freshness verification"
}

test_force_regeneration_preserves_brief_when_rendering_fails() {
  local home id brief fake_root status archive_count module
  home="$TMP_ROOT/failed-regeneration-home"
  id=failed-regeneration-guard
  brief="$home/data/$id/brief.md"
  fake_root="$home/fake-root"
  module="$fake_root/.agents/skills/just-say-no-to-process-porn-and-ceremony/assets/credit-rules.md"
  mkdir -p "$(dirname "$brief")" "$fake_root/bin" "$(dirname "$module")"
  printf '%s\n' 'original brief must survive a failed regeneration' > "$brief"
  printf '%s\n' '# CREDIT RULES (binding)' > "$module"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fake_root/bin/fm-project-mode.sh"
  chmod +x "$fake_root/bin/fm-project-mode.sh"

  status=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    "$ROOT/bin/fm-brief.sh" "$id" some-proj --force-regenerate >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed regeneration must return the render failure"
  assert_grep "original brief must survive" "$brief" \
    "failed regeneration removed or changed the live brief"
  archive_count=$(find "$(dirname "$brief")" -maxdepth 1 -type f -name 'brief.md.archive-*' | wc -l | tr -d ' ')
  [ "$archive_count" = 0 ] || fail "failed regeneration archived the live brief before rendering"
  pass "fm-brief.sh: failed force regeneration preserves the live brief"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_grep "Do not create or modify CI workflow files (.woodpecker/, .github/workflows/) or shared CI scripts unless this brief's Task section explicitly assigns CI ownership; if your change seems to need a CI edit, append \`blocked:\` and stop." "$brief" \
      "$id: ship brief missing the CI ownership guardrail"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

test_every_generated_instruction_carries_honest_work_credit_rules() {
  local home id brief kind count expected_module actual_module
  home="$TMP_ROOT/honest-work-home"
  mkdir -p "$home/data"
  expected_module=$(cat "$ROOT/.agents/skills/just-say-no-to-process-porn-and-ceremony/assets/credit-rules.md")

  for kind in ship scout secondmate; do
    id="honest-work-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" sample-project >"$home/$id.out" 2>"$home/$id.err"
        ;;
      scout)
        FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" sample-project --scout >"$home/$id.out" 2>"$home/$id.err"
        ;;
      secondmate)
        FM_HOME="$home" FM_SECONDMATE_CHARTER='Review honest work.' \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >"$home/$id.out" 2>"$home/$id.err"
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$kind instruction was not generated"
    assert_grep '# CREDIT RULES (binding)' "$brief" \
      "$kind instruction omitted the binding credit-rules module"
    assert_grep 'When the assigned work changes code, real code and real tests must ship in the same work item.' "$brief" \
      "$kind instruction omitted the scoped code-plus-tests credit floor"
    assert_grep 'Knowledge-only work, including a scout report, does not authorize implementation; deliver only the assigned evidence or report.' "$brief" \
      "$kind instruction omitted the knowledge-only scope boundary"
    assert_grep 'Mocks, fixtures, captures, and replay are never live proof.' "$brief" \
      "$kind instruction omitted the proof-class boundary"
    assert_grep 'An explicitly assigned knowledge deliverable is authorized by that assignment' "$brief" \
      "$kind instruction omitted the assigned knowledge-deliverable boundary"
    assert_grep 'Do not create any other process artifact unless it names a concrete consumer' "$brief" \
      "$kind instruction omitted the process-artifact creation gate"
    assert_grep 'A worker or subagent report is a claim, not evidence.' "$brief" \
      "$kind instruction omitted the report-is-a-claim boundary"
    assert_grep 'No-Claim: Green tests prove only the exercised behavior' "$brief" \
      "$kind instruction omitted the explicit No-Claim boundary"
    count=$(grep -Fc '# CREDIT RULES (binding)' "$brief")
    [ "$count" = 1 ] || fail "$kind instruction rendered the canonical module $count times"
    actual_module=$(awk '
      /^# CREDIT RULES \(binding\)$/ { capture=1 }
      /^# (Charter|Task)$/ && capture { exit }
      capture { print }
    ' "$brief")
    [ "$actual_module" = "$expected_module" ] \
      || fail "$kind instruction did not transport the complete canonical credit-rules module"
  done
  pass "fm-brief.sh: ship, scout, and secondmate instructions carry one binding credit-rules module"
}

test_every_generated_instruction_carries_simple_english_rule() {
  local home id brief kind rule
  home="$TMP_ROOT/simple-english-home"
  mkdir -p "$home/data"
  rule="Any text the captain reads directly, including reports, summaries, and captain-facing documents, must follow \`~/.claude/skills/simple-english\` in pragmatic mode. Use 20 words per instruction and 25 words per description. Use active voice and one instruction or fact per sentence. Do not use \`should\`, \`may\`, or \`might\`. Agent-to-agent and internal text is exempt."

  for kind in ship scout secondmate; do
    id="simple-english-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" sample-project >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" sample-project --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_SECONDMATE_CHARTER='Review captain-facing text.' \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "$rule" "$brief" \
      "$kind instruction omitted the captain-facing simple-English rule"
  done
  pass "fm-brief.sh: ship, scout, and secondmate instructions carry the simple-English rule"
}

test_missing_honest_work_module_refuses_before_writing_a_brief() {
  local home fake_root id out err status=0
  home="$TMP_ROOT/honest-work-missing-home"
  fake_root="$TMP_ROOT/honest-work-missing-root"
  id=honest-work-missing
  out="$home/generate.out"
  err="$home/generate.err"
  mkdir -p "$home/data" "$fake_root"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    "$ROOT/bin/fm-brief.sh" "$id" sample-project >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "a missing honest-work module must stop instruction generation"
  assert_grep 'required honest-work credit-rules module is missing or unreadable' "$err" \
    "missing honest-work module did not produce the owning diagnostic"
  assert_grep "$fake_root/.agents/skills/just-say-no-to-process-porn-and-ceremony/assets/credit-rules.md" "$err" \
    "missing-module diagnostic did not identify the canonical module"
  assert_absent "$home/data/$id/brief.md" \
    "missing honest-work module still left a launchable instruction file"
  pass "fm-brief.sh: a missing canonical credit-rules module refuses before writing a brief"
}

test_whitespace_only_honest_work_module_refuses_before_writing_a_brief() {
  local home fake_root id err status=0 module
  home="$TMP_ROOT/honest-work-whitespace-home"
  fake_root="$TMP_ROOT/honest-work-whitespace-root"
  id=honest-work-whitespace
  err="$home/generate.err"
  module="$fake_root/.agents/skills/just-say-no-to-process-porn-and-ceremony/assets/credit-rules.md"
  mkdir -p "$home/data" "$(dirname "$module")"
  printf ' \t\n  \n' >"$module"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    "$ROOT/bin/fm-brief.sh" "$id" sample-project >/dev/null 2>"$err" || status=$?
  expect_code 1 "$status" "a whitespace-only honest-work module must stop instruction generation"
  assert_grep 'required honest-work credit-rules module is empty' "$err" \
    "whitespace-only honest-work module did not produce the owning diagnostic"
  assert_absent "$home/data/$id/brief.md" \
    "whitespace-only honest-work module still left a launchable instruction file"
  pass "fm-brief.sh: a whitespace-only canonical credit-rules module refuses before writing a brief"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "firstmate's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_ship_briefs_carry_agent_dogfood_contract() {
  local home id brief
  home="$TMP_ROOT/dogfood-home"
  write_registry "$home"

  for id_proj in "brief-dogfood-nm1:no-registry-proj" "brief-dogfood-dp2:direct-proj" "brief-dogfood-lo3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "# Agent dogfood - user-facing changes" "$brief" \
      "$id: ship brief missing the agent dogfood contract"
    assert_grep "agent-executed UAT of the REAL running feature" "$brief" \
      "$id: ship brief missing the real-feature UAT doctrine"
    assert_grep "CHROME_DEVTOOLS_AXI_SESSION=$id" "$brief" \
      "$id: ship brief missing the task-keyed isolated browser profile"
    assert_grep "real CLI/API surface when that IS the user surface" "$brief" \
      "$id: ship brief missing the CLI/API user-surface alternative"
    assert_grep "A mismatch means NOT done" "$brief" \
      "$id: ship brief missing the mismatch-is-not-done rule"
    assert_grep "what to try in 60 seconds" "$brief" \
      "$id: ship brief missing the captain 60-second try requirement"
    assert_grep "an explicit claim, never a silent skip" "$brief" \
      "$id: ship brief missing the explicit non-user-facing justification rule"
  done
  pass "fm-brief.sh: every ship delivery mode carries the agent dogfood contract"
}

test_ship_done_templates_require_agent_dogfood_evidence() {
  local home brief
  home="$TMP_ROOT/dogfood-done-home"
  write_registry "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dogfood-done-nm no-registry-proj >/dev/null 2>&1
  brief="$home/data/dogfood-done-nm/brief.md"
  assert_grep "append \`done: {summary}\` to the status file and stop. The done report must also carry" "$brief" \
    "no-mistakes pre-pipeline done template does not require dogfood evidence"
  assert_grep "append \`done: PR {url} checks green\` and stop. The done report must also carry" "$brief" \
    "no-mistakes post-CI done template does not require dogfood evidence"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dogfood-done-dp direct-proj >/dev/null 2>&1
  brief="$home/data/dogfood-done-dp/brief.md"
  assert_grep "append \`done: PR {url}\` to the status file and stop. The done report must also carry" "$brief" \
    "direct-PR done template does not require dogfood evidence"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dogfood-done-lo local-proj >/dev/null 2>&1
  brief="$home/data/dogfood-done-lo/brief.md"
  assert_grep "append \`done: ready in branch fm/dogfood-done-lo\` to the status file and stop. The done report must also carry" "$brief" \
    "local-only done template does not require dogfood evidence"
  pass "fm-brief.sh: every ship done template requires dogfood evidence"
}

test_scout_and_secondmate_omit_agent_dogfood_contract() {
  local home brief
  home="$TMP_ROOT/dogfood-scope-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dogfood-scout alpha --scout >/dev/null 2>&1
  brief="$home/data/dogfood-scout/brief.md"
  assert_no_grep "# Agent dogfood" "$brief" \
    "scout brief must not carry the ship dogfood contract"
  assert_no_grep "CHROME_DEVTOOLS_AXI_SESSION" "$brief" \
    "scout brief must not carry the isolated browser profile instruction"
  FM_HOME="$home" FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    "$ROOT/bin/fm-brief.sh" dogfood-sm --secondmate alpha >/dev/null 2>&1
  brief="$home/data/dogfood-sm/brief.md"
  assert_no_grep "# Agent dogfood" "$brief" \
    "secondmate charter must not carry the ship dogfood contract"
  assert_no_grep "CHROME_DEVTOOLS_AXI_SESSION" "$brief" \
    "secondmate charter must not carry the isolated browser profile instruction"
  pass "fm-brief.sh: scout and secondmate scaffolds omit the ship dogfood contract"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper module_dir
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  module_dir="$foreign_root/.agents/skills/just-say-no-to-process-porn-and-ceremony/assets"
  mkdir -p "$home/data" "$module_dir"
  cp "$ROOT/.agents/skills/just-say-no-to-process-porn-and-ceremony/assets/credit-rules.md" \
    "$module_dir/credit-rules.md"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_script_parses
test_no_heredoc_in_command_substitution
test_help_includes_entire_header
test_ship_task_guidance_is_structured_and_proportional
test_existing_brief_refusal_detects_staleness_and_force_regenerates
test_existing_current_brief_still_requires_freshness_verification
test_force_regeneration_preserves_brief_when_rendering_fails
test_ship_modes_generate_clean_briefs
test_every_generated_instruction_carries_honest_work_credit_rules
test_every_generated_instruction_carries_simple_english_rule
test_missing_honest_work_module_refuses_before_writing_a_brief
test_whitespace_only_honest_work_module_refuses_before_writing_a_brief
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_ship_briefs_carry_agent_dogfood_contract
test_ship_done_templates_require_agent_dogfood_evidence
test_scout_and_secondmate_omit_agent_dogfood_contract
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
