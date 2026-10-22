import Foundation
import Testing
@testable import PitboxKit

// Everyday commands keep their honest class: plain ones stay Not flagged, so the ticks on red lines keep meaning
// something. A row is (text, the class in a local session).

@Suite struct CommandClassifierEverydayTests {
    static let rows: [(String, CommandAssessment.Class)] = [
        ("git add -A && git commit -m \"Fix\" && git push", .notFlagged),
        ("git stash && git pull --rebase && git stash pop", .notFlagged),
        ("git checkout -b feature/x", .notFlagged),
        ("git reset HEAD~1", .notFlagged),
        ("git log --oneline | head -20", .notFlagged),
        ("gh pr create --fill", .notFlagged),
        ("gh run watch", .notFlagged),
        ("brew install gh", .notFlagged),
        ("brew update && brew upgrade", .notFlagged),
        ("open https://github.com/x/y/pull/12", .notFlagged),
        ("ls -la ~/Library/Application\\ Support/Pitbox/", .notFlagged),
        ("tail -f ~/Library/Logs/x.log", .notFlagged),
        ("defaults read com.apple.dock", .notFlagged),
        ("curl -s https://api.github.com/repos/x/y | jq '.stargazers_count'", .notFlagged),
        ("docker ps -a", .notFlagged),
        ("ssh box1", .notFlagged),
        ("mkdir -p ~/x && cd ~/x", .notFlagged),
        ("diff <(sort a) <(sort b)", .notFlagged),
        ("grep -rn \"TODO\" Sources/", .notFlagged),
        ("sed -i '' 's/foo/bar/g' file.txt", .notFlagged),
        ("ps aux | grep -i claude", .notFlagged),
        ("lsof -i :8080", .notFlagged),
        ("printf '%s\\n' \"$PATH\" | tr ':' '\\n'", .notFlagged),
        ("for f in *.md; do wc -l \"$f\"; done", .notFlagged),
        ("if [ -d ~/x ]; then echo yes; fi", .notFlagged),
        ("cat ~/.zshrc | grep PATH", .notFlagged),
        ("jq . package.json", .notFlagged),
        ("pbpaste | wc -c", .notFlagged),
        ("tmux attach -t main", .notFlagged),
        ("code .", .notFlagged),
        ("say \"done\"", .notFlagged),
        ("ln -s ~/x ~/y", .notFlagged),
        ("cp -R ~/x ~/y", .notFlagged),
        ("rsync -av ~/x/ /Volumes/Backup/x/", .notFlagged),
        ("echo $SHELL && which python3 && uname -a && sw_vers", .notFlagged),
        ("du -sh ~/Library/Caches/*", .notFlagged),
        ("export ANTHROPIC_API_KEY=\"$(security find-generic-password -s ANTHROPIC_API_KEY -w)\"", .notFlagged),
        ("security add-generic-password -U -a \"$USER\" -s SERVICE_TOKEN -w", .notFlagged),
        ("read -r \"?Token: \" t && security add-generic-password -U -a \"$USER\" -s T -w \"$t\"", .notFlagged),
        ("caffeinate -d", .notFlagged),
        ("curl -I https://example.org", .notFlagged),
        ("wc -l < README.md > count.txt", .notFlagged),
        ("echo \"$(date): done\" >> ~/notes.txt", .notFlagged),
        ("cat <<'EOF' > notes.md\n# Title\nSome $text here\nEOF", .notFlagged),
        ("[[ -f .env ]] && cat .env | wc -l", .notFlagged),
        ("npm run build", .risky),
        ("cd ~/my\\ project && swift build", .risky),
        ("python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt", .risky),
        ("kill $(lsof -ti :3000)", .risky),
        ("echo \"export PATH=\\\"/opt/homebrew/bin:$PATH\\\"\" >> ~/.zprofile", .risky),
        ("find . -name \"*.swift\" | xargs wc -l", .risky),
        ("rm -rf node_modules && npm install", .risky),
        ("launchctl list | grep pitbox", .risky),
        ("osascript -e 'display notification \"x\"'", .risky),
        ("sudo softwareupdate -ia", .risky),
        ("ssh-keygen -t ed25519 -C \"me@x\"", .risky),
        ("npx prettier --write .", .risky),
        ("chmod +x scripts/x.sh && ./scripts/x.sh", .risky),
    ]

    @Test func everydayCommandsKeepAnHonestClass() {
        for (n, row) in Self.rows.enumerated() {
            let a = CC.assess(row.0)
            #expect(a.commandClass == row.1, "row \(n + 1): \(a.commandClass.rawValue), flags \(a.flags.map(\.rule.rawValue))")
        }
    }
}
