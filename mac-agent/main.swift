import AppKit

/*
 * Точка входа вынесена в отдельный файл: при сборке из нескольких исходников
 * Swift разрешает выражения верхнего уровня только в main.swift.
 */
let delegate = AppDelegate()
let application = NSApplication.shared

application.delegate = delegate
// .accessory — живём только в строке состояния, без иконки в Dock.
application.setActivationPolicy(.accessory)
application.run()
