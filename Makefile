# Top-level Makefile for ~/.claude.
#
# Targets:
#   test          — run every test surface, aggregate, fail if score < THRESHOLD
#   test-reviewer — run only the reviewer harness (currently the only surface)
#   help          — list targets
#
# Variables (override on command line, e.g. `make test RUNS=5 THRESHOLD=90`):
#   RUNS       runs per (wrapper x fixture) pair                  default 10
#   THRESHOLD  pass cutoff for OVERALL percentage                 default 80

SHELL := /usr/bin/env bash

CLAUDE_HOME    ?= $(HOME)/.claude
REVIEWER_DIR   := $(CLAUDE_HOME)/hooks/tests/reviewer
REVIEWER_RUNNER:= $(REVIEWER_DIR)/runner.sh

RUNS      ?= 10
THRESHOLD ?= 80

.DEFAULT_GOAL := test

.PHONY: test test-reviewer help

test: test-reviewer

test-reviewer:
	@"$(REVIEWER_RUNNER)" "$(RUNS)" "$(THRESHOLD)"

help:
	@echo "Targets:"
	@echo "  test           run all tests, aggregate score, fail if < THRESHOLD% (default)"
	@echo "  test-reviewer  run only the reviewer harness"
	@echo "  help           this message"
	@echo
	@echo "Variables:"
	@echo "  RUNS=N         runs per (wrapper x fixture) pair  (default 10)"
	@echo "  THRESHOLD=PCT  OVERALL pass cutoff in percent      (default 80)"
