import Foundation
import Testing
@testable import PitboxKit

// Ways a reply could hide a dangerous command from the reader: quoting and spelling traps, commands inside other
// commands' words, and code that reaches a shell sideways. Each must still be found.

@Suite struct CommandClassifierEvasionTests {
    @Test func quotingAndSpellingTraps() {
        for text in ["\"r\"\"m\" -rf ~", "r''m -rf ~", "\\r\\m -rf ~", "$'rm' -rf ~", "r$'\\x6d' -rf ~", "'/bin/rm' -rf ~",
                     "command rm -rf ~", "builtin command rm -rf ~", "xargs rm -rf ~ < /dev/null", "sudo -u x rm -rf ~",
                     "{rm,-rf,~}", "{r,}m -rf ~", "env -i FOO=1 rm -rf ~", "nice -10 rm -rf ~", "time -p rm -rf ~",
                     "timeout -s KILL 5 rm -rf ~", "busybox rm -rf ~", "exec -a x rm -rf ~", "rm -rf ~ &", "rm -rf -- ~",
                     "rm $'-rf' ~", "rm -rf \"$(echo ~)\"", "R\\M -rf ~", "/usr/../bin/rm -rf ~"] {
            #expect(CC.rules(text).contains(.b6), "B6 expected")
        }
    }

    @Test func commandsInsideOtherCommandsWords() {
        for text in ["sh -c '\"$@\"' _ rm -rf ~", "bash -c 'exec \"$0\" \"$@\"' rm -rf ~", "zsh -c '$1 $2 $3' x rm -rf ~",
                     "env -S 'rm -rf ~'", "watch -n 1 'rm -rf ~'", "su -c 'rm -rf ~' root", "eval 'rm -rf ~'",
                     "ssh -o ProxyCommand='rm -rf ~' box1", "rsync -e 'sh -c \"rm -rf ~\"' a box1:", "git -c core.pager='rm -rf ~' log",
                     "git config alias.x '!rm -rf ~'", "osascript -e 'do shell script \"rm -rf ~\"'",
                     "awk 'BEGIN { system(\"rm -rf ~\") }'", "find . -exec sh -c 'rm -rf ~' \\;",
                     "xargs -I% sh -c 'rm -rf ~'", "nohup sh -c 'rm -rf ~' &"] {
            #expect(CC.rules(text).contains(.b6), "B6 expected")
        }
    }

    @Test func codeThatReachesAShellSideways() {
        for text in ["source /dev/stdin <<'EOF'\nrm -rf ~\nEOF", ". /dev/stdin <<< 'rm -rf ~'", "bash /dev/stdin <<EOF\nrm -rf ~\nEOF",
                     "sh - <<'EOF'\nrm -rf ~\nEOF", "printf 'rm -rf ~' | sh", "printf '%s\\n' 'rm -rf ~' | bash",
                     "cat <<'EOF' | zsh -s\nrm -rf ~\nEOF", "echo 'rm -rf ~' | sudo sh", "sh <<< \"rm -rf ~\""] {
            #expect(CC.rules(text).contains(.b6), "B6 expected")
        }
        // Decoded text written to a file and then run.
        #expect(CC.rules("echo cm0gLXJmIH4= | base64 -d > x.sh\nsh x.sh").contains(.b5))
        #expect(CC.rules("base64 -d -i x.b64 -o run.sh; chmod +x run.sh; ./run.sh").contains(.b5))
        // Arithmetic that evaluates a variable whose text holds a command.
        let a = CC.rules("x='a[$(rm -rf ~)]'; echo $((x))")
        #expect(a.contains(.r11))
        #expect(a.contains(.b6))
        #expect(!CC.rules("x=5; echo $((x + 1))").contains(.r11))
    }

    @Test func placeholdersAreAlsoReadAsZshWouldReadThemUnedited() {
        // `<evil>` reads as a word for the placeholder, and as `<evil >` redirections for what zsh would do.
        let a = CC.assess("cat <evil> /etc/sudoers")
        #expect(a.commandClass == .needsEditing)
        #expect(a.flags.contains { $0.rule == .r5 })
        #expect(CC.assess("cat <image> /dev/disk2").commandClass == .blocked)
        let b = CC.assess("rm -rf <dir> ~")
        #expect(b.flags.filter { $0.rule == .r2 }.count == 1)
        #expect(CC.assess("ssh <server>").flags.isEmpty)
    }

    @Test func untrustedNumbersAndLineEndsNeverTrap() {
        for text in ["echo {-9223372036854775808..9223372036854775807}", "echo {0..9223372036854775807..1}",
                     "echo {9223372036854775807..-9223372036854775808}", "echo {1..99999999999999999999999}"] {
            #expect(ShellCommandScanner.scan(text).isReadable)
            _ = CC.assess(text)
        }
        #expect(CC.assess("echo a\r\necho b").lineCount == 2)
        #expect(CC.assess("echo a\r\necho b").commandClass == .blocked)
    }

    @Test func lookAlikeUserNamesForWrappers() {
        #expect(CC.rules("sudo -u p\u{0430}trick ls").contains(.b2))
        #expect(CC.rules("sudo --user=p\u{0430}trick ls").contains(.b2))
        #expect(!CC.rules("sudo -u alex ls").contains(.b2))
    }

    @Test func pathAndLoaderChanges() {
        #expect(CC.rules("env PATH=/tmp/x ls").contains(.r11))
        #expect(CC.rules("sudo PATH=/tmp/x ls").contains(.r11))
        #expect(CC.rules("DYLD_INSERT_LIBRARIES=x.dylib ls").contains(.r18))
        #expect(CC.rules("export NODE_OPTIONS='--require ./x.js'; node app.js").contains(.r18))
        #expect(!CC.rules("export EDITOR=vim").contains(.r18))
    }

    @Test func movingOrDeletingStartupFilesAndDestroyingWholeFolders() {
        #expect(CC.rules("mv ~/.zshrc /tmp/").contains(.r5))
        #expect(CC.rules("rm ~/.ssh/authorized_keys").contains(.r5))
        #expect(CC.rules("cp -R dotfiles/. ~").contains(.r5))
        #expect(CC.rules("rsync -a dotfiles/ ~/").contains(.r5))
        #expect(!CC.rules("cp -R x ~/Documents/").contains(.r5))
        #expect(CC.rules("rm -rf ~/.ssh").contains(.b6))
        #expect(CC.rules("find ~ -delete").contains(.b6))
        #expect(CC.rules("find / -exec rm -rf {} +").contains(.b6))
        #expect(!CC.rules("find ~ -name '*.tmp' -delete").contains(.b6))
        #expect(CC.rules("find . -delete").contains(.b6))           // the run folder
    }
}
