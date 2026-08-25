#!/usr/bin/env bash
set -euo pipefail

mode="${1:-worktree}"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
cd "$repo_root"

case "$mode" in
  staged) candidate_command=(git diff --cached --name-only -z --diff-filter=ACMR) ;;
  tracked) candidate_command=(git ls-files -z) ;;
  worktree) candidate_command=(git ls-files -co --exclude-standard -z) ;;
  *) printf '%s\n' "privacy-check: unsupported mode: $mode" >&2; exit 2 ;;
esac

typeset -a files
while IFS= read -r -d '' file; do
  files+=("$file")
done < <("${candidate_command[@]}")

if (( ${#files[@]} == 0 )); then
  exit 0
fi

failed=0
report() {
  printf '%s\n' "privacy-check: $1: $2" >&2
  failed=1
}

expected_name="AskaTsai"
expected_email="31321477+AskaTsai@users.noreply.github.com"
actual_name="$(git config --local --get user.name || true)"
actual_email="$(git config --local --get user.email || true)"
if [[ -n "$actual_name" || -n "$actual_email" ]]; then
  [[ "$actual_name" == "$expected_name" ]] || report "unexpected Git author name" "repository configuration"
  [[ "$actual_email" == "$expected_email" ]] || report "unexpected Git author email" "repository configuration"
fi

email_pattern='[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}'
token_pattern='(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,})'
private_key_pattern='-----BEGIN [A-Z0-9 ]+PRIVATE KEY-----'
slash='/'; home_path_pattern="${slash}Users${slash}"

for file in "${files[@]}"; do
  [[ -f "$file" ]] || continue
  scan_contents=1

  case "$file" in
    .env|.env.*|*/.env|*/.env.*|.zshrc|.zshrc.*|*/.zshrc|*/.zshrc.*|*.pem|*.key|*.p12|*.mobileprovision|*.log|*.bak|*backup*|.DS_Store)
      report "sensitive filename" "$file"
      continue
      ;;
  esac

  case "$file" in
    *.swift|*.md|*.sh|*.plist|*.yml|*.yaml|.gitignore|.githooks/*|scripts/*) ;;
    Resources/AppIcon.png|Resources/AppIcon.icns|Resources/AppIcon.iconset/*.png)
      scan_contents=0
      if git cat-file -e "HEAD:$file" 2>/dev/null && ! git diff --cached --quiet -- "$file"; then
        report "binary asset changed; review metadata before allowing it" "$file"
      fi
      ;;
    *)
      mime_type="$(file -b --mime-type "$file" 2>/dev/null || true)"
      case "$mime_type" in
        text/*|application/json|application/xml|application/x-shellscript) ;;
        *) report "unreviewed binary or unsupported file" "$file" ;;
      esac
      ;;
  esac

  (( scan_contents == 1 )) || continue

  if grep -Fq -- "$home_path_pattern" "$file" || grep -Fq -- "file:${slash}${slash}${slash}Users${slash}" "$file"; then
    report "personal absolute path" "$file"
  fi
  if grep -Eq -- "$private_key_pattern" "$file"; then
    report "private key marker" "$file"
  fi
  if grep -Eq -- "$token_pattern" "$file"; then
    report "credential-shaped value" "$file"
  fi

  while IFS= read -r email; do
    [[ -z "$email" || "$email" == "$expected_email" ]] || report "non-noreply email address" "$file"
  done < <(grep -Eo -- "$email_pattern" "$file" || true)
done

(( failed == 0 )) || exit 1
