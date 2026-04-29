#!/bin/bash
# Shared GitHub Copilot bearer-token fetcher for reviewer hooks.
#
# Exchanges the long-lived PAT (oauth_token from ~/.config/github-copilot/apps.json)
# for a short-lived Copilot bearer (~30 min) via api.github.com/copilot_internal/v2/token.
# Caches the bearer at $HOME/.cache/claude-proof/copilot/token.json and refreshes when
# expires_at - now < 60s (clock-skew margin). flock'd so concurrent hooks don't stampede.
#
# Sets on success:
#   COPILOT_BEARER       — short-lived token; pass via -H Authorization, NEVER body
# Returns:
#   0 on success, non-zero on any failure (missing apps.json, exchange HTTP error,
#   missing jq). Callers must check the rc and fail-open (exit 0) on non-zero.
#
# SECURITY:
#   - PAT (oauth_token) NEVER logged, never written to dump files, only flows from
#     apps.json -> curl Authorization header.
#   - Bearer cached on disk with mode 600 (apps.json itself is mode 600).
#   - No token value of either kind appears in any echo/printf/log path.

copilot_get_bearer() {
  COPILOT_BEARER=""
  local apps_file="$HOME/.config/github-copilot/apps.json"
  local cache_dir="$HOME/.cache/claude-proof/copilot"
  local cache_file="$cache_dir/token.json"
  local lock_file="$cache_dir/token.lock"

  command -v jq >/dev/null 2>&1 || return 1
  [ -r "$apps_file" ] || return 1

  mkdir -p "$cache_dir" 2>/dev/null || return 1
  chmod 700 "$cache_dir" 2>/dev/null || true

  exec 9>"$lock_file" || return 1
  flock 9 || { exec 9>&-; return 1; }

  local now exp
  now=$(date +%s)
  if [ -r "$cache_file" ]; then
    exp=$(jq -r '.expires_at // 0' "$cache_file" 2>/dev/null)
    case "$exp" in *[!0-9]*) exp=0 ;; "") exp=0 ;; esac
    if [ "$exp" -gt $((now + 60)) ]; then
      COPILOT_BEARER=$(jq -r '.token // empty' "$cache_file" 2>/dev/null)
      if [ -n "$COPILOT_BEARER" ]; then
        exec 9>&-
        return 0
      fi
    fi
  fi

  local pat
  pat=$(jq -r '
    to_entries
    | map(select(.key | startswith("github.com:")))
    | map(select(.value.oauth_token != null and (.value.oauth_token | length) > 0))
    | .[0].value.oauth_token // empty
  ' "$apps_file" 2>/dev/null)
  if [ -z "$pat" ]; then
    exec 9>&-
    return 1
  fi

  local resp http
  resp=$(curl -sS --max-time 30 \
    -w '\n%{http_code}' \
    -H "authorization: token $pat" \
    -H 'accept: application/json' \
    -H 'editor-version: vscode/1.95.0' \
    -H 'editor-plugin-version: copilot-chat/0.26.7' \
    -H 'user-agent: GitHubCopilotChat/0.26.7' \
    -H 'x-github-api-version: 2025-04-01' \
    'https://api.github.com/copilot_internal/v2/token' 2>/dev/null)
  http=$(printf '%s' "$resp" | tail -n1)
  local body
  body=$(printf '%s' "$resp" | sed '$d')
  case "$http" in
    2*) ;;
    *) exec 9>&-; return 1 ;;
  esac

  COPILOT_BEARER=$(printf '%s' "$body" | jq -r '.token // empty' 2>/dev/null)
  local new_exp
  new_exp=$(printf '%s' "$body" | jq -r '.expires_at // 0' 2>/dev/null)
  case "$new_exp" in *[!0-9]*) new_exp=0 ;; "") new_exp=0 ;; esac
  if [ -z "$COPILOT_BEARER" ] || [ "$new_exp" -le 0 ]; then
    exec 9>&-
    return 1
  fi

  local tmp
  tmp=$(mktemp "$cache_dir/token.XXXXXX") || { exec 9>&-; return 1; }
  printf '{"token":%s,"expires_at":%s}\n' \
    "$(printf '%s' "$COPILOT_BEARER" | jq -Rs .)" \
    "$new_exp" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$cache_file"
  exec 9>&-
  return 0
}
