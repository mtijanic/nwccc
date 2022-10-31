import std/[logging, terminal]

type ColoredConsoleLogger* = ref object of Logger
  parent: ConsoleLogger

proc newColoredConsoleLogger*(levelThreshold = lvlAll, fmtStr = defaultFmtStr): ColoredConsoleLogger =
  new result
  result.fmtStr = fmtStr
  result.levelThreshold = levelThreshold
  result.parent = newConsoleLogger(levelThreshold, fmtStr)

method log*(log: ColoredConsoleLogger, level: Level, args: varargs[string, `$`]) =
  defer:
    if stdout.isatty:
      stdout.resetAttributes()
      stdout.flushFile()

  if stdout.isatty:
    let (fgCol, fgStyle) = case level
    of lvlAll: (fgDefault, {})
    of lvlNone: (fgDefault, {})

    of lvlDebug: (fgDefault, {styleDim})
    of lvlInfo: (fgDefault, {})
    of lvlNotice: (fgGreen, {})
    of lvlWarn: (fgYellow, {})
    of lvlError: (fgRed, {styleBright})
    of lvlFatal: (fgRed, {styleBright, styleUnderscore})

    if fgStyle.len > 0: stdout.setStyle(fgStyle)
    stdout.setForegroundColor(fgCol)

  log(log.parent, level, args)
