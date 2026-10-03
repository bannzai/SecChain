import Foundation

/// Writes one line of a command's result to standard output: names, counts, and confirmations the
/// caller asked for, never a secret value. The result goes straight to the file descriptor, as the
/// output of `mask` does, because it is what the command returns and not a log; static analysis
/// treats `print` as logging. A command writes all of its lines here instead of mixing in `print`,
/// which is buffered, so that its lines stay in order when standard output is a pipe.
func writeToStandardOutput(line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}
