# NativQL

A native macOS SQL client for **PostgreSQL** and **MySQL**. Fast, focused, and
fully local — connection details, queries, and results never leave your machine.

> 🚧 NativQL is in early development. Features below describe the v1 target.

## Highlights (v1)

- Native SwiftUI app — no Electron
- PostgreSQL + MySQL behind a unified driver architecture
- Multi-tab workspace: syntax-highlighted SQL editor above a virtualized
  results grid
- Inline cell editing with transactional, primary-key-based commits
- Query history and saved queries with folders
- CSV / JSON export, DDL viewer, EXPLAIN tree view
- Full SSL mode support for both engines

## Building

1. Clone the repository:

   ```bash
   git clone https://github.com/nativql/nativql.git
   cd nativql
   ```

2. Open the project in Xcode:

   ```bash
   open NativQL.xcodeproj
   ```

3. Configure code signing:
   - Select the **NativQL** target → **Signing & Capabilities**
   - Choose your team (a free "Personal Team" works)

4. Build and run with `⌘R`.

### Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15.3+ / Swift 5.10+

### Running tests

Pure-logic and driver packages test without Xcode:

```bash
cd Packages/NativQLKit && swift test
```

Integration tests run against real servers via Docker and are gated behind an
environment flag so they never block a plain `swift test`:

```bash
docker compose up -d          # starts postgres:16 and mysql:8
NATIVQL_INTEGRATION=1 swift test   # inside Packages/PostgresDriver or MySQLDriver
```

## Security notes

v1 stores connection passwords in plaintext JSON under
`~/Library/Application Support/NativQL/` with `600` file permissions. This is a
known tradeoff; Keychain integration is planned. Do not use v1 on shared
machines if this matters to you.

## License

[MIT](LICENSE)
