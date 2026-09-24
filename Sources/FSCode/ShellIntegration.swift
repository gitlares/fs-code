import Foundation

/// Per-session shell setup. It never writes to a user's dotfiles.
struct ShellIntegration {
    let directory: URL

    static func make(for shell: String) -> ShellIntegration? {
        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh" else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSCode-zsh-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try script.data(using: .utf8)?.write(to: directory.appendingPathComponent(".zshenv"))
            return ShellIntegration(directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    func environmentEntries(from environment: [String: String]) -> [String] {
        var entries = ["ZDOTDIR=\(directory.path)", "FSCODE_ZSH_BOOTSTRAP=1"]
        if let original = environment["ZDOTDIR"] {
            entries += ["FSCODE_ORIGINAL_ZDOTDIR=\(original)", "FSCODE_HAS_ORIGINAL_ZDOTDIR=1"]
        }
        return entries
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static let script = #"""
if [[ -n ${FSCODE_ZSH_BOOTSTRAP-} && -z ${FSCODE_ZSH_BOOTSTRAPPED-} ]]; then
  typeset -g FSCODE_ZSH_BOOTSTRAPPED=1
  if [[ ${FSCODE_HAS_ORIGINAL_ZDOTDIR-} == 1 ]]; then
    export ZDOTDIR="$FSCODE_ORIGINAL_ZDOTDIR"
  else
    unset ZDOTDIR
  fi
  unset FSCODE_ORIGINAL_ZDOTDIR FSCODE_HAS_ORIGINAL_ZDOTDIR FSCODE_ZSH_BOOTSTRAP
  if [[ -r ${ZDOTDIR-$HOME}/.zshenv ]]; then
    source "${ZDOTDIR-$HOME}/.zshenv"
  fi
  autoload -Uz add-zsh-hook
  _fscode_prompt_once() {
    local fscode_last_status=$?
    add-zsh-hook -d precmd _fscode_prompt_once
    unset -f _fscode_prompt_once
    if [[ -n ${NO_COLOR-} && ${FSCODE_DEFAULT_CLICOLOR-} == 1 && ${CLICOLOR-} == 1 ]]; then
      unset CLICOLOR
    fi
    unset FSCODE_DEFAULT_CLICOLOR
    [[ $(whence -w precmd) == 'precmd: function' || ${#precmd_functions} > 0 ]] && return $fscode_last_status
    [[ -n ${NO_COLOR-} || $PROMPT != '%n@%m %1~ %# ' ]] && return $fscode_last_status
    PROMPT='%F{4}%1~%f %(?.%F{2}%#%f.%F{1}[%?] %#%f) '
    return $fscode_last_status
  }
  add-zsh-hook precmd _fscode_prompt_once
fi
"""#
}
