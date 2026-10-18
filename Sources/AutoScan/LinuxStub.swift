#if !os(macOS)
// Програма працює лише на macOS. Цей файл дозволяє зібрати й протестувати
// ядро (AutoScanCore) на інших системах.
@main
enum LinuxStub {
    static func main() { print("AutoScan працює лише на macOS") }
}
#endif
