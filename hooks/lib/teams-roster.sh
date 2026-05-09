#!/usr/bin/env bash
# Helpers for reading the agent-team roster.
#
# Source of truth: ~/.claude/teams/<team>/config.json. Each config has a
# `members[]` array; relevant fields are `name` (the short label used by
# SendMessage's `to` arg) and `agentId` (the `name@team` form).
#
# Override the teams root via CLAUDE_TEAMS_ROOT for tests.

teams_roster_root() {
  printf '%s\n' "${CLAUDE_TEAMS_ROOT:-$HOME/.claude/teams}"
}

teams_roster_team_config() {
  local team="$1"
  printf '%s/%s/config.json\n' "$(teams_roster_root)" "$team"
}

# Print "name<TAB>agentId" per member of the given team.
# rc=1 when the config is missing.
teams_roster_team_members() {
  local team="$1"
  local cfg
  cfg="$(teams_roster_team_config "$team")"
  [ -f "$cfg" ] || return 1
  jq -r '.members[]? | [.name // "", .agentId // ""] | @tsv' "$cfg" 2>/dev/null
}

# rc=0 when recipient matches a member's name OR agentId in the given team.
teams_roster_team_has_recipient() {
  local team="$1" recipient="$2"
  local name agentId
  while IFS=$'\t' read -r name agentId; do
    [ -n "$name" ] && [ "$name" = "$recipient" ] && return 0
    [ -n "$agentId" ] && [ "$agentId" = "$recipient" ] && return 0
  done < <(teams_roster_team_members "$team" 2>/dev/null)
  return 1
}

# Print one team name per line (every directory under the teams root that
# has a config.json).
teams_roster_all_teams() {
  local root
  root="$(teams_roster_root)"
  [ -d "$root" ] || return 0
  local d
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/config.json" ] && basename "$d"
  done
  return 0
}

# Print "team<TAB>name<TAB>agentId" for every member across all teams.
teams_roster_global_members() {
  local team name agentId
  while IFS= read -r team; do
    [ -n "$team" ] || continue
    while IFS=$'\t' read -r name agentId; do
      printf '%s\t%s\t%s\n' "$team" "$name" "$agentId"
    done < <(teams_roster_team_members "$team" 2>/dev/null)
  done < <(teams_roster_all_teams)
  return 0
}

# rc=0 when recipient appears in any team's roster.
teams_roster_global_has_recipient() {
  local recipient="$1"
  local team name agentId
  while IFS=$'\t' read -r team name agentId; do
    [ -n "$name" ] && [ "$name" = "$recipient" ] && return 0
    [ -n "$agentId" ] && [ "$agentId" = "$recipient" ] && return 0
  done < <(teams_roster_global_members)
  return 1
}

# Multi-line roster of one team, suitable for embedding in a deny reason.
teams_roster_team_pretty() {
  local team="$1"
  local name agentId first=1
  printf 'Team "%s" roster:\n' "$team"
  while IFS=$'\t' read -r name agentId; do
    printf '  - %s (agentId: %s)\n' "$name" "$agentId"
    first=0
  done < <(teams_roster_team_members "$team" 2>/dev/null)
  if [ "$first" = "1" ]; then
    printf '  (no members in config)\n'
  fi
  return 0
}

# Multi-line roster across every known team.
teams_roster_global_pretty() {
  local team name agentId any=0
  while IFS= read -r team; do
    [ -n "$team" ] || continue
    any=1
    printf 'Team "%s":\n' "$team"
    while IFS=$'\t' read -r name agentId; do
      printf '  - %s (agentId: %s)\n' "$name" "$agentId"
    done < <(teams_roster_team_members "$team" 2>/dev/null)
  done < <(teams_roster_all_teams)
  if [ "$any" = "0" ]; then
    printf '(no teams found at %s)\n' "$(teams_roster_root)"
  fi
  return 0
}
