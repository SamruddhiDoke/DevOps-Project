# Contributing

## Workflow

1. Branch from `main`: `git switch -c feature/<short-name>`.
2. Make a focused change with tests.
3. Run the local quality gates (below). All must pass.
4. Commit with a clear message (`type(scope): summary`, e.g. `fix(backend): reject negative stock`).
5. Open a pull request; Jenkins runs the full pipeline on `main` after merge.

## Local quality gates

```powershell
# Backend: unit, integration, concurrency and failure-path tests + coverage report
cd order-inventory-platform\backend
mvn -B clean verify                      # report: target\site\jacoco\index.html

# Frontend: lint, tests with coverage, production build
cd ..\frontend
npm ci
npm run lint
npm run test:coverage
npm run build

# Whole stack in Docker (from the repository root, Git Bash or WSL)
./scripts/compose-acceptance-test.sh
```

Optional, when you change infrastructure:

```powershell
cd terraform; terraform fmt -check -recursive; terraform validate
helm lint helm/order-inventory --strict --set image.tag=dev
```

## Rules

- **Never commit secrets.** `.env`, `ci/.env`, `*.tfstate`, `*.tfplan`, `ansible/inventory.ini` and
  keys are git-ignored; keep it that way. Use `.env.example` with placeholders. If a secret is ever
  committed, treat it as compromised: rotate it first, then clean history (see docs/SECURITY.md).
- **Database changes go through Flyway.** Add a new `V<n>__description.sql` under
  `backend/src/main/resources/db/migration`; never edit a migration that has been applied anywhere.
  Hibernate only validates the schema (`ddl-auto=validate`).
- **Keep API contracts stable.** New fields may be added; renames/removals need a migration plan.
- **Images are immutable.** Never deploy `latest`; tags are `<build>-<commit>`.
- **Tool versions are pinned** in `ci/jenkins/Dockerfile` and `ansible/group_vars/all.yml`; update both together.
- Keep changes small enough that a failing test points at the cause.
