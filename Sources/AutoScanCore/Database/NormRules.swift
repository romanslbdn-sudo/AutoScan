import Foundation

/// Як має виглядати сигнал у нормі (для малюнка «Як має бути»).
public enum SignalShape: Hashable, Sendable {
    /// Рівний сигнал у межах коридору.
    case steady
    /// Сигнал, що постійно перемикається між двома рівнями (лямбда-зонд до каталізатора).
    case switching
    /// Рівні імпульси (датчики колінвала / розподільного вала).
    case pulses
}

public enum NormVerdict: Hashable, Sendable {
    case normal
    case low
    case high
    case absent
    case unstable
    case waiting

    public var title: String {
        switch self {
        case .normal: return "У нормі"
        case .low: return "Нижче норми"
        case .high: return "Вище норми"
        case .absent: return "Сигналу немає"
        case .unstable: return "Сигнал нестабільний"
        case .waiting: return "Потрібна умова перевірки"
        }
    }

    public var isProblem: Bool {
        switch self {
        case .normal, .waiting: return false
        default: return true
        }
    }
}

/// Поточні дані, з якими порівнюємо норму.
public struct NormContext: Sendable {
    public var current: [UInt8: Double]
    public var history: [UInt8: [Double]]
    public var isDiesel: Bool

    public init(current: [UInt8: Double], history: [UInt8: [Double]], isDiesel: Bool) {
        self.current = current; self.history = history; self.isDiesel = isDiesel
    }

    var rpm: Double? { current[0x0C] }
    var running: Bool { (rpm ?? 0) > 400 }
    /// Холостий хід: авто стоїть, педаль відпущена (дросель прикритий).
    /// Оберти не обмежуємо жорстко — інакше завищений холостий хід ніколи б не перевірявся.
    var idle: Bool {
        guard running, (current[0x0D] ?? 0) < 3 else { return false }
        if let throttle = current[0x11] { return throttle < 22 && (rpm ?? 0) < 1600 }
        if let load = current[0x04] { return load < 35 && (rpm ?? 0) < 1600 }
        return (rpm ?? 0) < 1100
    }
    var warm: Bool { (current[0x05] ?? 90) >= 70 }
}

public struct NormResult: Sendable {
    public let verdict: NormVerdict
    public let actualText: String
    public let explanation: String
}

/// Одна перевірка «Норма vs зараз» для певного сигналу.
public struct NormCheck: Identifiable, Sendable {
    public let id: String
    public let pid: UInt8
    public let title: String
    /// Як має бути (текстом).
    public let expected: String
    /// За яких умов перевіряти.
    public let condition: String
    public let lo: Double
    public let hi: Double
    public let shape: SignalShape
    public let evaluate: @Sendable (NormContext) -> NormResult

    public var unit: String { PIDTable.definition(pid)?.unit ?? "" }
}

// MARK: - Допоміжні функції оцінки

private func fmt(_ v: Double, _ pid: UInt8) -> String {
    let def = PIDTable.definition(pid)
    return (def?.format(v) ?? String(format: "%.1f", v)) + " " + (def?.unit ?? "")
}

private func stdev(_ a: [Double]) -> Double {
    guard a.count > 1 else { return 0 }
    let m = a.reduce(0, +) / Double(a.count)
    return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count - 1)).squareRoot()
}

/// Стандартна оцінка «значення в коридорі».
private func bandCheck(id: String, pid: UInt8, title: String, lo: Double, hi: Double,
                       expected: String, condition: String,
                       requires: @escaping @Sendable (NormContext) -> String? = { _ in nil },
                       low: String, high: String, absent: String,
                       normal: String = "Значення в межах норми — цей сигнал, найімовірніше, не причина помилки.") -> NormCheck {
    NormCheck(id: id, pid: pid, title: title, expected: expected, condition: condition, lo: lo, hi: hi, shape: .steady) { ctx in
        guard let v = ctx.current[pid] else {
            return NormResult(verdict: .absent, actualText: "немає даних", explanation: absent)
        }
        if let need = requires(ctx) {
            return NormResult(verdict: .waiting, actualText: fmt(v, pid), explanation: need)
        }
        if v < lo { return NormResult(verdict: .low, actualText: fmt(v, pid), explanation: low) }
        if v > hi { return NormResult(verdict: .high, actualText: fmt(v, pid), explanation: high) }
        return NormResult(verdict: .normal, actualText: fmt(v, pid), explanation: normal)
    }
}

private let needRunning: @Sendable (NormContext) -> String? = { ctx in
    ctx.running ? nil : "Заведіть двигун — цей сигнал перевіряється на працюючому двигуні."
}
private let needWarmIdle: @Sendable (NormContext) -> String? = { ctx in
    if !ctx.running { return "Заведіть двигун і дайте йому попрацювати на холостому." }
    if !ctx.warm { return "Двигун ще холодний. Дочекайтеся, поки температура рідини підніметься вище 70 °C." }
    if !ctx.idle { return "Відпустіть газ — перевірка на холостому ходу без руху." }
    return nil
}

// MARK: - Перевірки

public enum NormRules {

    static func fuelTrim(bank: Int, long: Bool) -> NormCheck {
        let pid: UInt8 = bank == 1 ? (long ? 0x07 : 0x06) : (long ? 0x09 : 0x08)
        let kind = long ? "Довга" : "Коротка"
        return bandCheck(
            id: "trim-\(bank)-\(long)", pid: pid,
            title: "\(kind) корекція палива, ряд \(bank)", lo: -10, hi: 10,
            expected: "від −10 до +10 % (ідеально — близько 0)",
            condition: "Прогрітий двигун, холостий хід або рівний рух",
            requires: needRunning,
            low: "Блок ЗАБИРАЄ паливо — суміш занадто багата. Шукайте: протікання форсунок, завеликий тиск палива, несправний ДМРВ/датчик температури.",
            high: "Блок ДОДАЄ паливо понад норму — він компенсує нестачу палива або зайве повітря. Це підтверджує бідну суміш: підсмоктування повітря, забруднений ДМРВ, слабкий тиск палива.",
            absent: "Авто не повідомляє корекцію палива по цьому ряду.")
    }

    static let mafIdle = NormCheck(
        id: "maf-idle", pid: 0x10, title: "Витрата повітря (ДМРВ) на холостому",
        expected: "орієнтовно 2–7 г/с (двигун 1,4–2,0 л); приблизно 2,5–3 г/с на кожен літр об'єму",
        condition: "Прогрітий двигун, холостий хід, споживачі вимкнені",
        lo: 2, hi: 7, shape: .steady) { ctx in
        guard let v = ctx.current[0x10] else {
            return .init(verdict: .absent, actualText: "немає даних",
                         explanation: "Сигналу ДМРВ немає: датчик відключений, обрив проводки або авто працює без ДМРВ (за датчиком тиску MAP).")
        }
        if let need = needWarmIdle(ctx) { return .init(verdict: .waiting, actualText: fmt(v, 0x10), explanation: need) }
        if v < 2 { return .init(verdict: .low, actualText: fmt(v, 0x10), explanation: "ДМРВ показує замало повітря. Найчастіше — забруднена плівка датчика або підсмоктування повітря ПІСЛЯ датчика (повітря йде в обхід вимірювання). Двигун при цьому отримує бідну суміш.") }
        if v > 7.5 { return .init(verdict: .high, actualText: fmt(v, 0x10), explanation: "Для двигуна до 2 л це забагато на холостому. Якщо двигун більший — значення може бути нормальним. Інакше — несправний ДМРВ або великі оберти холостого ходу.") }
        return .init(verdict: .normal, actualText: fmt(v, 0x10), explanation: "Витрата повітря в нормі для типового двигуна 1,4–2,0 л.")
    }

    static let mapIdle = NormCheck(
        id: "map-idle", pid: 0x0B, title: "Тиск у впускному колекторі на холостому",
        expected: "бензин: 25–45 кПа (розрідження); дизель: близько атмосферного (95–105 кПа)",
        condition: "Прогрітий двигун, холостий хід",
        lo: 25, hi: 45, shape: .steady) { ctx in
        guard let v = ctx.current[0x0B] else {
            return .init(verdict: .absent, actualText: "немає даних", explanation: "Сигналу датчика MAP немає: датчик відключений або обрив проводки.")
        }
        if let need = needWarmIdle(ctx) { return .init(verdict: .waiting, actualText: fmt(v, 0x0B), explanation: need) }
        if ctx.isDiesel {
            return (85...110).contains(v)
                ? .init(verdict: .normal, actualText: fmt(v, 0x0B), explanation: "Для дизеля на холостому тиск близький до атмосферного — це нормально.")
                : .init(verdict: v < 85 ? .low : .high, actualText: fmt(v, 0x0B), explanation: "Для дизеля на холостому тиск має бути близьким до атмосферного. Перевірте датчик MAP і його шланг.")
        }
        if v < 22 { return .init(verdict: .low, actualText: fmt(v, 0x0B), explanation: "Розрідження сильніше за норму — можлива несправність датчика або закритий дросель при високих обертах.") }
        if v > 50 { return .init(verdict: .high, actualText: fmt(v, 0x0B), explanation: "Розрідження слабке. Причини: підсмоктування повітря, проблеми з клапанами (низька компресія), розтягнутий ланцюг ГРМ, забитий вихлоп або несправний датчик.") }
        return .init(verdict: .normal, actualText: fmt(v, 0x0B), explanation: "Розрідження в колекторі нормальне — впуск герметичний.")
    }

    static func boost(over: Bool) -> NormCheck {
        NormCheck(
            id: over ? "boost-over" : "boost-under", pid: 0x0B,
            title: over ? "Максимальний тиск наддуву" : "Тиск наддуву під навантаженням",
            expected: over ? "не вище ~250 кПа абсолютного тиску (залежить від двигуна)"
                           : "під навантаженням >70 %: зазвичай 150–250 кПа (0,5–1,5 бар надлишкового)",
            condition: "Різкий розгін на 2–3 передачі від ~2000 об/хв (тільки на безпечній дорозі)",
            lo: over ? 100 : 150, hi: over ? 250 : 260, shape: .steady) { ctx in
            let maps = ctx.history[0x0B] ?? []
            let loads = ctx.history[0x04] ?? []
            guard let cur = ctx.current[0x0B] else {
                return .init(verdict: .absent, actualText: "немає даних",
                             explanation: "Авто не передає тиск у колекторі (MAP) через OBD2 — перевірка наддуву недоступна.")
            }
            let peak = maps.max() ?? cur
            let peakLoad = loads.max() ?? (ctx.current[0x04] ?? 0)
            let baro = ctx.current[0x33] ?? 100
            let text = "пік \(Int(peak)) кПа (надлишковий \(String(format: "%.2f", max(0, peak - baro) / 100)) бар)"
            if peakLoad < 70 {
                return .init(verdict: .waiting, actualText: "зараз \(Int(cur)) кПа",
                             explanation: "Потрібне навантаження: розженіться з педаллю газу в підлогу на 2–3 передачі (на безпечній дорозі). Програма запам'ятає найбільший тиск.")
            }
            if over {
                return peak > 255
                    ? .init(verdict: .high, actualText: text, explanation: "Турбіна дає більше тиску, ніж безпечно. Перевірте клапан керування наддувом (вестгейт / геометрію) і вакуумні шланги керування.")
                    : .init(verdict: .normal, actualText: text, explanation: "Перенаддуву зараз немає. Якщо помилка з'являється — можливо, вестгейт підклинює лише інколи.")
            }
            if peak < 140 {
                return .init(verdict: .low, actualText: text,
                             explanation: "Турбіна не набирає тиск. Найчастіше — витік повітря після турбіни (патрубки, інтеркулер, хомути), підклинює геометрія або вестгейт відкритий, несправний клапан керування наддувом.")
            }
            return .init(verdict: .normal, actualText: text, explanation: "Тиск наддуву під навантаженням нормальний.")
        }
    }

    static func lambdaUpstream(bank: Int) -> NormCheck {
        let pid: UInt8 = bank == 1 ? 0x14 : 0x18
        return NormCheck(
            id: "o2-up-\(bank)", pid: pid, title: "Лямбда-зонд до каталізатора, ряд \(bank)",
            expected: "постійно «стрибає» між 0,1 і 0,9 В кілька разів на секунду",
            condition: "Прогрітий двигун, холостий хід або 2000 об/хв",
            lo: 0.1, hi: 0.9, shape: .switching) { ctx in
            let h = Array((ctx.history[pid] ?? []).suffix(40))
            guard let v = ctx.current[pid] else {
                return .init(verdict: .absent, actualText: "немає даних", explanation: "Сигналу зонда немає: обрив проводки, несправний зонд, або у авто широкосмуговий зонд (його напруга через OBD2 не показується).")
            }
            if let need = needWarmIdle(ctx) { return .init(verdict: .waiting, actualText: fmt(v, pid), explanation: need) }
            guard h.count >= 12 else {
                return .init(verdict: .waiting, actualText: fmt(v, pid), explanation: "Збираю дані сигналу… зачекайте кілька секунд.")
            }
            let lo = h.min() ?? v, hi = h.max() ?? v
            let range = String(format: "%.2f–%.2f В", lo, hi)
            if hi - lo < 0.15 {
                return .init(verdict: .absent, actualText: "стоїть на \(range)", explanation: "Зонд не перемикається — напруга стоїть на місці. Зонд несправний, не прогрівся (перевірте підігрів) або обрив сигналу.")
            }
            if hi < 0.6 {
                return .init(verdict: .low, actualText: range, explanation: "Зонд майже весь час показує БІДНУ суміш (низька напруга, не доходить до 0,8–0,9 В). Підсмоктування повітря, нестача палива або підсмоктування повітря у вихлопі перед зондом.")
            }
            if lo > 0.3 {
                return .init(verdict: .high, actualText: range, explanation: "Зонд майже весь час показує БАГАТУ суміш (не падає до 0,1–0,2 В). Протікають форсунки, завеликий тиск палива або зонд забруднений.")
            }
            return .init(verdict: .normal, actualText: range, explanation: "Зонд перемикається у повному діапазоні — він живий, суміш регулюється.")
        }
    }

    static func lambdaDownstream(bank: Int, catalyst: Bool) -> NormCheck {
        let pid: UInt8 = bank == 1 ? 0x15 : 0x19
        let upPid: UInt8 = bank == 1 ? 0x14 : 0x18
        return NormCheck(
            id: "o2-down-\(bank)", pid: pid, title: "Лямбда-зонд після каталізатора, ряд \(bank)",
            expected: "майже рівна лінія 0,5–0,8 В (каталізатор «згладжує» коливання)",
            condition: "Прогрітий двигун, 2000–2500 об/хв протягом хвилини",
            lo: 0.45, hi: 0.85, shape: .steady) { ctx in
            let h = Array((ctx.history[pid] ?? []).suffix(40))
            guard let v = ctx.current[pid] else {
                return .init(verdict: .absent, actualText: "немає даних", explanation: "Сигналу другого зонда немає: обрив проводки або несправний зонд.")
            }
            if let need = needRunning(ctx) { return .init(verdict: .waiting, actualText: fmt(v, pid), explanation: need) }
            guard h.count >= 12 else {
                return .init(verdict: .waiting, actualText: fmt(v, pid), explanation: "Збираю дані сигналу… зачекайте кілька секунд.")
            }
            let swing = (h.max() ?? v) - (h.min() ?? v)
            let upSwing = { () -> Double in
                let u = Array((ctx.history[upPid] ?? []).suffix(40))
                return (u.max() ?? 0) - (u.min() ?? 0)
            }()
            let range = String(format: "%.2f–%.2f В", h.min() ?? v, h.max() ?? v)
            if swing > 0.4 && upSwing > 0.4 && catalyst {
                return .init(verdict: .unstable, actualText: range,
                             explanation: "Другий зонд коливається майже так само, як перший. Це означає, що каталізатор більше не накопичує кисень і не очищує вихлоп — він зношений.")
            }
            let avg = h.reduce(0, +) / Double(h.count)
            if avg < 0.35 {
                return .init(verdict: .low, actualText: range, explanation: "Після каталізатора зонд показує бідну суміш. Можливе підсмоктування повітря у вихлопі (прогорілі прокладки, тріщина) або несправний зонд.")
            }
            if stdev(h) < 0.005 && (avg < 0.05 || avg > 1.0) {
                return .init(verdict: .absent, actualText: range, explanation: "Сигнал «мертвий» — схоже на обрив або несправний зонд.")
            }
            return .init(verdict: .normal, actualText: range, explanation: catalyst
                         ? "Після каталізатора сигнал рівний — каталізатор працює."
                         : "Сигнал другого зонда в нормі.")
        }
    }

    static let rpmPresent = NormCheck(
        id: "crank", pid: 0x0C, title: "Сигнал обертів (датчик колінвала)",
        expected: "рівні імпульси від кожного зуба диска; оберти є і плавні",
        condition: "Двигун працює (або крутиться стартером)",
        lo: 600, hi: 7000, shape: .pulses) { ctx in
        let h = Array((ctx.history[0x0C] ?? []).suffix(30))
        guard let v = ctx.current[0x0C] else {
            return .init(verdict: .absent, actualText: "немає даних", explanation: "Блок не передає оберти — сигналу датчика колінвала немає.")
        }
        if v < 50 {
            return .init(verdict: .absent, actualText: "0 об/хв",
                         explanation: "Блок бачить 0 обертів. Якщо двигун зараз працює або крутиться стартером, а тут 0 — імпульсів від датчика колінвала НЕМАЄ: перевірте датчик, його зазор, проводку і задаючий диск.")
        }
        let jitter = stdev(h)
        if h.count >= 10 && ctx.idle && jitter > 60 {
            return .init(verdict: .unstable, actualText: "\(Int(v)) об/хв, коливання ±\(Int(jitter))",
                         explanation: "Імпульси є, але оберти нерівні. Це може бути наслідком пропусків запалювання або «брудного» сигналу датчика (бруд на датчику, пошкоджені зуби диска).")
        }
        return .init(verdict: .normal, actualText: "\(Int(v)) об/хв",
                     explanation: "Імпульси від колінвала є — блок бачить рівні оберти. Помилка могла бути разовою (поганий контакт). Точну форму імпульсу можна побачити лише осцилографом.")
    }

    static let camRpm = NormCheck(
        id: "cam", pid: 0x0C, title: "Синхронізація валів (через оберти)",
        expected: "двигун заводиться швидко, оберти рівні; імпульс розподільного вала — один на два оберти колінвала",
        condition: "Двигун працює",
        lo: 600, hi: 7000, shape: .pulses) { ctx in
        guard let v = ctx.current[0x0C], v > 50 else {
            return .init(verdict: .waiting, actualText: "двигун не працює", explanation: "Заведіть двигун. Якщо він заводиться довго (кілька секунд стартером) — це типова ознака відсутності сигналу розподільного вала.")
        }
        return .init(verdict: .normal, actualText: "\(Int(v)) об/хв",
                     explanation: "Двигун працює, отже блок синхронізувався. Сигнал розподільного вала через OBD2 напряму не видно — якщо помилка повертається, перевірте датчик, проводку і натяг ланцюга/ременя ГРМ.")
    }

    static let idleStability = NormCheck(
        id: "idle-stab", pid: 0x0C, title: "Рівність обертів холостого ходу",
        expected: "650–950 об/хв, коливання не більше ±25 об/хв",
        condition: "Прогрітий двигун, холостий хід",
        lo: 650, hi: 950, shape: .steady) { ctx in
        let h = Array((ctx.history[0x0C] ?? []).suffix(25))
        guard let v = ctx.current[0x0C] else {
            return .init(verdict: .absent, actualText: "немає даних", explanation: "Блок не передає оберти.")
        }
        if let need = needWarmIdle(ctx) { return .init(verdict: .waiting, actualText: "\(Int(v)) об/хв", explanation: need) }
        guard h.count >= 10 else { return .init(verdict: .waiting, actualText: "\(Int(v)) об/хв", explanation: "Збираю дані… зачекайте кілька секунд.") }
        let j = stdev(h)
        let text = "\(Int(v)) об/хв, коливання ±\(Int(j))"
        if j > 35 {
            return .init(verdict: .unstable, actualText: text, explanation: "Оберти «пливуть» — двигун трясе. Це типова картина пропусків запалювання: свічки, котушки, форсунки, підсмоктування повітря.")
        }
        if v < 620 { return .init(verdict: .low, actualText: text, explanation: "Оберти холостого ходу занизькі — забруднений дросель/регулятор ХХ, велике навантаження.") }
        if v > 1000 { return .init(verdict: .high, actualText: text, explanation: "Оберти холостого ходу зависокі — підсмоктування повітря або регулятор ХХ.") }
        return .init(verdict: .normal, actualText: text, explanation: "Холостий хід рівний — зараз пропусків не видно. Вони можуть з'являтися лише під навантаженням або на холодну.")
    }

    static let coolant = NormCheck(
        id: "ect", pid: 0x05, title: "Температура охолоджувальної рідини",
        expected: "після прогріву 80–105 °C; прогрів до 80 °C — за 10–15 хв роботи",
        condition: "Двигун працює щонайменше 10 хвилин",
        lo: 80, hi: 105, shape: .steady) { ctx in
        guard let v = ctx.current[0x05] else {
            return .init(verdict: .absent, actualText: "немає даних", explanation: "Блок не передає температуру рідини.")
        }
        let text = fmt(v, 0x05)
        if v <= -39 { return .init(verdict: .absent, actualText: text, explanation: "−40 °C — це «обрив»: датчик відключений або перебита проводка.") }
        if v >= 135 { return .init(verdict: .high, actualText: text, explanation: "Неправдоподібно висока температура — схоже на замикання проводки датчика. Якщо двигун реально гарячий — зупиніться!") }
        if v > 108 { return .init(verdict: .high, actualText: text, explanation: "ПЕРЕГРІВ! Заглушіть двигун. Перевірте рівень рідини, вентилятор радіатора, термостат і помпу.") }
        let runtime = ctx.current[0x1F] ?? 0
        if v < 75 {
            if runtime > 0 && runtime < 600 {
                return .init(verdict: .waiting, actualText: text, explanation: "Двигун ще прогрівається (працює \(Int(runtime / 60)) хв). Перевірте ще раз після 10–15 хвилин роботи.")
            }
            return .init(verdict: .low, actualText: text, explanation: "Двигун не прогрівається до робочої температури. Найчастіше — термостат заклинило у відкритому положенні.")
        }
        return .init(verdict: .normal, actualText: text, explanation: "Температура робоча.")
    }

    static let intakeAir = bandCheck(
        id: "iat", pid: 0x0F, title: "Температура повітря на впуску", lo: -30, hi: 70,
        expected: "близька до температури назовні (на ходу) або вища на 10–30 °C (на холостому)",
        condition: "Будь-коли",
        low: "Датчик показує неправдоподібно низьку температуру (−40 °C означає обрив проводки).",
        high: "Датчик показує дуже високу температуру — замикання проводки або датчик стоїть біля гарячого місця.",
        absent: "Блок не передає температуру повітря.")

    static let throttleIdle = bandCheck(
        id: "tps", pid: 0x11, title: "Положення дроселя на холостому", lo: 0, hi: 22,
        expected: "0–20 % при відпущеній педалі; плавно росте до 80–100 % при натисканні",
        condition: "Педаль газу відпущена",
        requires: { ctx in ctx.idle || !ctx.running ? nil : "Відпустіть педаль газу." },
        low: "Значення нижче нуля неможливе — помилка датчика.",
        high: "При відпущеній педалі дросель показує забагато — нагар у дросельному вузлі, зношений датчик або помилка калібрування.",
        absent: "Блок не передає положення дроселя.")

    static let idleRPM = bandCheck(
        id: "idle-rpm", pid: 0x0C, title: "Оберти холостого ходу", lo: 650, hi: 950,
        expected: "650–950 об/хв на прогрітому двигуні",
        condition: "Прогрітий двигун, холостий хід",
        requires: needWarmIdle,
        low: "Оберти занизькі — забруднений дросель або регулятор холостого ходу, велике навантаження від генератора/кондиціонера.",
        high: "Оберти зависокі — підсмоктування повітря (вакуумні шланги, прокладки) або заклинило регулятор холостого ходу.",
        absent: "Блок не передає оберти.")

    static let voltage = NormCheck(
        id: "volt", pid: 0x42, title: "Напруга бортової мережі",
        expected: "двигун працює: 13,5–14,8 В; заглушений: 12,4–12,8 В",
        condition: "Двигун працює (перевірка генератора) або заглушений (перевірка акумулятора)",
        lo: 13.5, hi: 14.8, shape: .steady) { ctx in
        guard let v = ctx.current[0x42] else {
            return .init(verdict: .absent, actualText: "немає даних", explanation: "Блок не передає напругу.")
        }
        let text = fmt(v, 0x42)
        if ctx.running {
            if v < 13.2 { return .init(verdict: .low, actualText: text, explanation: "Генератор не заряджає або заряджає слабо: щітки, реле-регулятор, ремінь, окислені клеми.") }
            if v > 15.0 { return .init(verdict: .high, actualText: text, explanation: "Перезаряд! Несправний реле-регулятор генератора — може зіпсувати акумулятор і електроніку.") }
            return .init(verdict: .normal, actualText: text, explanation: "Генератор заряджає нормально.")
        }
        if v < 12.2 { return .init(verdict: .low, actualText: text, explanation: "Акумулятор розряджений або старий. Зарядіть і перевірте під навантаженням.") }
        return .init(verdict: .normal, actualText: text, explanation: "Напруга акумулятора нормальна. Заведіть двигун, щоб перевірити генератор.")
    }

    static let egrError = bandCheck(
        id: "egr", pid: 0x2D, title: "Похибка клапана EGR", lo: -10, hi: 10,
        expected: "від −10 до +10 % (клапан відкривається так, як наказав блок)",
        condition: "Двигун працює, плавний рух",
        requires: needRunning,
        low: "Клапан EGR відкривається менше, ніж треба — нагар, підклинювання, слабкий привід.",
        high: "Клапан EGR відкривається більше, ніж треба, або не закривається — заклинив відкритим.",
        absent: "Авто не передає похибку EGR через OBD2.")

    static func railPressure() -> NormCheck {
        NormCheck(
            id: "rail", pid: 0x23, title: "Тиск у паливній рампі",
            expected: "дизель на холостому: орієнтовно 230–450 бар; пряме вприскування бензину: 30–120 бар (залежить від двигуна)",
            condition: "Двигун працює на холостому",
            lo: 230, hi: 450, shape: .steady) { ctx in
            guard let v = ctx.current[0x23] else {
                return .init(verdict: .absent, actualText: "немає даних", explanation: "Авто не передає тиск у рампі через OBD2.")
            }
            let text = fmt(v, 0x23)
            if let need = needRunning(ctx) { return .init(verdict: .waiting, actualText: text, explanation: need) }
            let range: ClosedRange<Double> = ctx.isDiesel ? 200...500 : 25...150
            if v < range.lowerBound { return .init(verdict: .low, actualText: text, explanation: "Тиск у рампі низький: паливний фільтр, підкачувальний насос, ТНВД, регулятор тиску або витік.") }
            if v > range.upperBound { return .init(verdict: .high, actualText: text, explanation: "Тиск у рампі високий: регулятор тиску / клапан дозування або датчик тиску.") }
            return .init(verdict: .normal, actualText: text, explanation: "Тиск у рампі в орієнтовній нормі для холостого ходу.")
        }
    }

    // MARK: Відповідність кодів перевіркам

    static func num(_ c: String) -> Int? {
        guard c.count == 5, c.hasPrefix("P0") else { return nil }
        return Int(c.dropFirst(2))
    }

    /// Перевірки, пов'язані з кодом несправності.
    public static func checks(for code: String) -> [NormCheck] {
        let c = code.uppercased()
        var list: [NormCheck] = []
        let n = num(c)

        func has(_ codes: String...) -> Bool { codes.contains(c) }
        func inRange(_ r: ClosedRange<Int>) -> Bool { n.map { r.contains($0) } ?? false }

        // Склад суміші
        if has("P0171", "P0172", "P2177", "P2187", "P2188", "P2195", "P2196") {
            list += [fuelTrim(bank: 1, long: true), fuelTrim(bank: 1, long: false), lambdaUpstream(bank: 1), mafIdle]
        }
        if has("P0174", "P0175") {
            list += [fuelTrim(bank: 2, long: true), fuelTrim(bank: 2, long: false), lambdaUpstream(bank: 2), mafIdle]
        }
        // ДМРВ / MAP
        if inRange(100...104) || has("P0068") { list += [mafIdle, fuelTrim(bank: 1, long: true)] }
        if inRange(105...108) || has("P0069") { list += [mapIdle] }
        // Температури
        if inRange(110...113) || has("P0097", "P0098") { list += [intakeAir] }
        if inRange(115...119) || has("P0125", "P0128", "P0217") { list += [coolant] }
        // Дросель
        if inRange(120...123) || inRange(220...223) || has("P2101", "P2111", "P2112", "P2135", "P0121") { list += [throttleIdle] }
        // Лямбда-зонди
        if inRange(130...134) || has("P0030") { list += [lambdaUpstream(bank: 1), fuelTrim(bank: 1, long: false)] }
        if inRange(136...140) || has("P0036", "P2096", "P2097") { list += [lambdaDownstream(bank: 1, catalyst: false)] }
        if inRange(150...154) { list += [lambdaUpstream(bank: 2)] }
        if inRange(156...160) { list += [lambdaDownstream(bank: 2, catalyst: false)] }
        if has("P0420", "P0421") { list += [lambdaUpstream(bank: 1), lambdaDownstream(bank: 1, catalyst: true)] }
        if has("P0430", "P0431") { list += [lambdaUpstream(bank: 2), lambdaDownstream(bank: 2, catalyst: true)] }
        // Паливо
        if has("P0087", "P0088", "P0089", "P0093") || inRange(190...193) { list += [railPressure()] }
        // Наддув
        if has("P0299", "P2263") || inRange(235...238) { list += [boost(over: false), mapIdle] }
        if has("P0234") { list += [boost(over: true)] }
        // Пропуски запалювання
        if inRange(300...316) || inRange(351...354) || inRange(201...212) {
            list += [idleStability, fuelTrim(bank: 1, long: true), fuelTrim(bank: 1, long: false)]
        }
        // Колінвал / розподільний вал
        if inRange(335...339) || has("P0320") { list += [rpmPresent] }
        if inRange(340...349) || has("P0016", "P0017", "P0011", "P0012", "P0014", "P0010") { list += [camRpm, idleStability] }
        // Холостий хід
        if inRange(505...507) { list += [idleRPM, throttleIdle] }
        // Напруга
        if inRange(560...563) || c.hasPrefix("U0") { list += [voltage] }
        // EGR
        if inRange(400...406) { list += [egrError] }

        // Прибрати дублікати, зберігши порядок
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// Усі PID, які потрібно опитувати для перевірок цих кодів.
    public static func requiredPIDs(for codes: [String]) -> Set<UInt8> {
        var set: Set<UInt8> = [0x0C, 0x05, 0x0D, 0x04, 0x1F, 0x33]
        for c in codes { for ch in checks(for: c) { set.insert(ch.pid) } }
        if codes.contains(where: { checks(for: $0).contains { $0.id.hasPrefix("o2-down") } }) {
            set.formUnion([0x14, 0x18])
        }
        return set
    }
}
