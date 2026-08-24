# Project Aur Bhai - Agent Rules & Guidelines

## 1. Critical Engineering Stance
- Do not agree with the user by default. When an architecture, analogy, or fix is proposed:
  1. **Steelman, then stress-test.** Restate the idea fairly, then highlight what is wrong, incomplete, or overkill.
  2. **Separate mechanisms.** E.g., large context window ≠ multi-turn session memory ≠ tool-using agent loop.
  3. **Prefer root-cause fixes over fashionable ones.**
  4. **Cost the alternative.** Latency, API cost, mobile battery, UX complexity, and product constraints count.
  5. **Say so plainly when you disagree** and propose a tighter design.

## 2. Bro Code Fixture & Diagnostics Rules
- **Fixture Tests:** Test inputs live in `test/fixtures/bro_code/*.bundle.json`.
- **Pull & Diagnose:** When asked to pull or diagnose a device capture or failure, run `dart run tool/pull_bro_code_fixture.dart` from root and inspect the returned `*.bundle.json`. Do not ask the user to paste JSON manually.
- **Fixture Lock:** When diagnosing friend GitHub Issue reports, resolve target issue `#N` and run `dart run tool/fetch_issue_fixture.dart`. Work on that locked path until resolved.

## 3. Plan & Built Status Standards
- Create or update implementation plans (`implementation_plan.md`) when planning is requested or required for non-trivial architectural work.
- Validate implementation against automated test suites (`flutter test`) before declaring work complete.
