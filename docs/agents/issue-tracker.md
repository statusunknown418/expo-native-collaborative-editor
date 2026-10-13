# Issue tracker: GitHub

Issues and specs live in GitHub Issues for `statusunknown418/expo-native-collaborative-editor`. Use the `gh` CLI.

Run commands inside this clone; `gh` resolves the repository from `origin`. Outside this clone, pass `--repo statusunknown418/expo-native-collaborative-editor` to `gh issue` and `gh pr` commands.

## Conventions

- **Create**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read**: `gh issue view <number> --json number,title,body,labels,comments`.
- **List**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`. Adjust `--label` and `--state` filters.
- **Sub-issues**: create the child, then run `gh api --method POST repos/statusunknown418/expo-native-collaborative-editor/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`. Fetch its database ID with `gh api repos/statusunknown418/expo-native-collaborative-editor/issues/<child> --jq .id`. If sub-issues are unavailable, put `Part of #<parent>` at the top of the child body and link it in the parent's task list.
- **Comment**: `gh issue comment <number> --body "..."`.
- **Labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`. Use the role mapping in `triage-labels.md`.
- **Close**: `gh issue close <number> --comment "..."`.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares one number space across issues and PRs. For an ambiguous `#42`, resolve with `gh pr view 42`, falling back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Read the issue and comments using the Read command above.

## Wayfinding operations

Used by `/wayfinder`. The map is one issue with child issues as tickets.

- **Map**: create an issue labelled `wayfinder:map`, holding Notes / Decisions-so-far / Fog.
- **Child ticket**: link it as a sub-issue of the map. If unavailable, use the parent task list and `Part of #<map>` convention. Labels: `wayfinder:<type>` (`research`, `prototype`, `grilling`, `task`).
- **Blocking**: use native issue dependencies: `gh api --method POST repos/statusunknown418/expo-native-collaborative-editor/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`. Fetch the blocker's database ID with `gh api repos/statusunknown418/expo-native-collaborative-editor/issues/<blocker> --jq .id`; this is not the issue number or node ID. If dependencies are unavailable, put `Blocked by: #<n>, #<n>` at the top of the child body.
- **Frontier**: list the map's open children. Exclude assigned tickets and those with `issue_dependencies_summary.blocked_by > 0`, or any open blocker listed in the fallback line. First in map order wins.
- **Claim**: `gh issue edit <number> --add-assignee @me`, before starting work.
- **Resolve**: comment with the answer, close the ticket, then append a gist and link to the map's Decisions-so-far.
