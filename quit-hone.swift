// Usado pelo build.sh: pede a cada Hone aberto que saia, como pelo menu Sair
// (corre o applicationWillTerminate, por isso o Sleepy fica armado para o
// relançamento), e espera até 10 s que saia mesmo. Sai com 1 se não sair.
import AppKit

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tiagof.hone")
apps.forEach { $0.terminate() }

let deadline = Date().addingTimeInterval(10)
while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
exit(apps.allSatisfy(\.isTerminated) ? 0 : 1)
