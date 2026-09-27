import Foundation
import SQLite3

/// Thread-safe SQLite database manager for persisting battery, display, and session data.
/// Uses macOS's built-in libsqlite3 with WAL mode for crash resilience.
/// Zero external dependencies.
final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.batterysot.database", qos: .utility)
    private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databasePath: String? = nil) {
        let path: String
        if let databasePath = databasePath {
            path = databasePath
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("BatterySOT", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            path = appDir.appendingPathComponent("batterysot.sqlite").path
        }
        openDatabase(at: path)
        setupSchema()
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase(at path: String) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let errMsg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown"
            fatalError("BatterySOT: Failed to open database at \(path): \(errMsg)")
        }
        exec("PRAGMA journal_mode = WAL;")
        exec("PRAGMA synchronous = NORMAL;")
        exec("PRAGMA foreign_keys = ON;")
    }

    private func setupSchema() {
        let ddl = """
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            event_type TEXT NOT NULL,
            battery_percentage INTEGER,
            metadata TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);

        CREATE TABLE IF NOT EXISTS discharge_segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            cycle_id INTEGER NOT NULL,
            start_time REAL NOT NULL,
            end_time REAL,
            start_percentage INTEGER NOT NULL,
            end_percentage INTEGER,
            lowest_percentage INTEGER NOT NULL,
            screen_on_time REAL NOT NULL DEFAULT 0,
            screen_off_time REAL NOT NULL DEFAULT 0,
            sleep_time REAL NOT NULL DEFAULT 0,
            is_active INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_segments_cycle ON discharge_segments(cycle_id);

        CREATE TABLE IF NOT EXISTS charging_interruptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            cycle_id INTEGER NOT NULL,
            start_time REAL NOT NULL,
            end_time REAL,
            start_percentage INTEGER NOT NULL,
            end_percentage INTEGER,
            is_active INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_interruptions_cycle ON charging_interruptions(cycle_id);

        CREATE TABLE IF NOT EXISTS discharge_cycles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time REAL NOT NULL,
            end_time REAL,
            initial_percentage INTEGER NOT NULL,
            current_percentage INTEGER NOT NULL,
            lowest_percentage INTEGER NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_cycles_active ON discharge_cycles(is_active);

        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        exec(ddl)
    }

    // MARK: - Event Recording

    func recordEvent(_ event: SystemEvent) {
        queue.sync {
            let sql = "INSERT INTO events (timestamp, event_type, battery_percentage, metadata) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, event.eventType.rawValue, -1, SQLITE_TRANSIENT_PTR)
            if let pct = event.batteryPercentage {
                sqlite3_bind_int(stmt, 3, Int32(pct))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let meta = event.metadata {
                sqlite3_bind_text(stmt, 4, meta, -1, SQLITE_TRANSIENT_PTR)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_step(stmt)
        }
    }

    // MARK: - Discharge Cycle Management

    func createDischargeCycle(startTime: Date, initialPercentage: Int) -> Int64 {
        queue.sync {
            let sql = """
            INSERT INTO discharge_cycles (start_time, initial_percentage, current_percentage, lowest_percentage, is_active)
            VALUES (?, ?, ?, ?, 1);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, startTime.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(initialPercentage))
            sqlite3_bind_int(stmt, 3, Int32(initialPercentage))
            sqlite3_bind_int(stmt, 4, Int32(initialPercentage))
            sqlite3_step(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    func updateDischargeCycle(id: Int64, currentPercentage: Int, lowestPercentage: Int) {
        queue.sync {
            let sql = "UPDATE discharge_cycles SET current_percentage = ?, lowest_percentage = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(currentPercentage))
            sqlite3_bind_int(stmt, 2, Int32(lowestPercentage))
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    func endDischargeCycle(id: Int64, endTime: Date) {
        queue.sync {
            let sql = "UPDATE discharge_cycles SET end_time = ?, is_active = 0 WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, endTime.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    func getActiveDischargeCycle() -> (id: Int64, startTime: Date, initialPercentage: Int, currentPercentage: Int, lowestPercentage: Int)? {
        queue.sync {
            let sql = "SELECT id, start_time, initial_percentage, current_percentage, lowest_percentage FROM discharge_cycles WHERE is_active = 1 ORDER BY id DESC LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let id = sqlite3_column_int64(stmt, 0)
            let startTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let initial = Int(sqlite3_column_int(stmt, 2))
            let current = Int(sqlite3_column_int(stmt, 3))
            let lowest = Int(sqlite3_column_int(stmt, 4))
            return (id, startTime, initial, current, lowest)
        }
    }

    // MARK: - Discharge Segment Management

    func createDischargeSegment(cycleId: Int64, startTime: Date, startPercentage: Int) -> Int64 {
        queue.sync {
            let sql = """
            INSERT INTO discharge_segments (cycle_id, start_time, start_percentage, lowest_percentage, is_active)
            VALUES (?, ?, ?, ?, 1);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, cycleId)
            sqlite3_bind_double(stmt, 2, startTime.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(startPercentage))
            sqlite3_bind_int(stmt, 4, Int32(startPercentage))
            sqlite3_step(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    func updateDischargeSegment(id: Int64, endPercentage: Int?, lowestPercentage: Int,
                                screenOnTime: TimeInterval, screenOffTime: TimeInterval, sleepTime: TimeInterval) {
        queue.sync {
            let sql = """
            UPDATE discharge_segments SET end_percentage = ?, lowest_percentage = ?,
            screen_on_time = ?, screen_off_time = ?, sleep_time = ? WHERE id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            if let pct = endPercentage {
                sqlite3_bind_int(stmt, 1, Int32(pct))
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int(stmt, 2, Int32(lowestPercentage))
            sqlite3_bind_double(stmt, 3, screenOnTime)
            sqlite3_bind_double(stmt, 4, screenOffTime)
            sqlite3_bind_double(stmt, 5, sleepTime)
            sqlite3_bind_int64(stmt, 6, id)
            sqlite3_step(stmt)
        }
    }

    func endDischargeSegment(id: Int64, endTime: Date, endPercentage: Int) {
        queue.sync {
            let sql = "UPDATE discharge_segments SET end_time = ?, end_percentage = ?, is_active = 0 WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, endTime.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(endPercentage))
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    func getActiveDischargeSegment(cycleId: Int64) -> (id: Int64, startTime: Date, startPercentage: Int)? {
        queue.sync {
            let sql = "SELECT id, start_time, start_percentage FROM discharge_segments WHERE cycle_id = ? AND is_active = 1 ORDER BY id DESC LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, cycleId)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let id = sqlite3_column_int64(stmt, 0)
            let startTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let startPct = Int(sqlite3_column_int(stmt, 2))
            return (id, startTime, startPct)
        }
    }

    func getSegmentsForCycle(cycleId: Int64) -> [(screenOnTime: TimeInterval, screenOffTime: TimeInterval, sleepTime: TimeInterval, startPct: Int, endPct: Int?)] {
        queue.sync {
            let sql = "SELECT screen_on_time, screen_off_time, sleep_time, start_percentage, end_percentage FROM discharge_segments WHERE cycle_id = ? ORDER BY start_time ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, cycleId)
            var results: [(TimeInterval, TimeInterval, TimeInterval, Int, Int?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sot = sqlite3_column_double(stmt, 0)
                let soff = sqlite3_column_double(stmt, 1)
                let slp = sqlite3_column_double(stmt, 2)
                let sPct = Int(sqlite3_column_int(stmt, 3))
                let ePct: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 4))
                results.append((sot, soff, slp, sPct, ePct))
            }
            return results
        }
    }

    // MARK: - Charging Interruption Management

    func createChargingInterruption(cycleId: Int64, startTime: Date, startPercentage: Int) -> Int64 {
        queue.sync {
            let sql = """
            INSERT INTO charging_interruptions (cycle_id, start_time, start_percentage, is_active)
            VALUES (?, ?, ?, 1);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, cycleId)
            sqlite3_bind_double(stmt, 2, startTime.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(startPercentage))
            sqlite3_step(stmt)
            return sqlite3_last_insert_rowid(db)
        }
    }

    func endChargingInterruption(id: Int64, endTime: Date, endPercentage: Int) {
        queue.sync {
            let sql = "UPDATE charging_interruptions SET end_time = ?, end_percentage = ?, is_active = 0 WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, endTime.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(endPercentage))
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    func getActiveChargingInterruption(cycleId: Int64) -> (id: Int64, startPercentage: Int)? {
        queue.sync {
            let sql = "SELECT id, start_percentage FROM charging_interruptions WHERE cycle_id = ? AND is_active = 1 ORDER BY id DESC LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, cycleId)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return (sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int(stmt, 1)))
        }
    }

    func getChargingInterruptionsForCycle(cycleId: Int64) -> [(startPct: Int, endPct: Int?, startTime: Date, endTime: Date?)] {
        queue.sync {
            let sql = "SELECT start_percentage, end_percentage, start_time, end_time FROM charging_interruptions WHERE cycle_id = ? ORDER BY start_time ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, cycleId)
            var results: [(Int, Int?, Date, Date?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let sPct = Int(sqlite3_column_int(stmt, 0))
                let ePct: Int? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 1))
                let sTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let eTime: Date? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                results.append((sPct, ePct, sTime, eTime))
            }
            return results
        }
    }

    // MARK: - App State Persistence

    func saveAppState(key: String, value: String) {
        queue.sync {
            let sql = "INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT_PTR)
            sqlite3_step(stmt)
        }
    }

    func loadAppState(key: String) -> String? {
        queue.sync {
            let sql = "SELECT value FROM app_state WHERE key = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_PTR)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return String(cString: sqlite3_column_text(stmt, 0))
        }
    }

    // MARK: - Historical Data Queries

    func getDailySummaries(days: Int = 30) -> [DailySummary] {
        queue.sync {
            // Query events for the last N days and compute daily aggregates
            let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let sql = """
            SELECT date(timestamp, 'unixepoch', 'localtime') as day,
                   event_type, battery_percentage, timestamp
            FROM events
            WHERE timestamp >= ?
            ORDER BY timestamp ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, startDate.timeIntervalSince1970)

            // Accumulate events per day
            var dayData: [String: (sot: TimeInterval, soff: TimeInterval, sleep: TimeInterval, charging: TimeInterval,
                                   batteryUsed: Int, maxPct: Int, minPct: Int, cycleCount: Int,
                                   lastDisplayOn: TimeInterval?, lastScreensOff: TimeInterval?,
                                   lastSleep: TimeInterval?, lastChargeStart: TimeInterval?)] = [:]

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let dayPtr = sqlite3_column_text(stmt, 0),
                      let typePtr = sqlite3_column_text(stmt, 1) else { continue }
                let day = String(cString: dayPtr)
                let typeStr = String(cString: typePtr)
                let ts = sqlite3_column_double(stmt, 3)

                if dayData[day] == nil {
                    let pct = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? 100 : Int(sqlite3_column_int(stmt, 2))
                    dayData[day] = (0, 0, 0, 0, 0, pct, pct, 0, nil, nil, nil, nil)
                }

                guard var d = dayData[day] else { continue }

                if let pct = (sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 2))) {
                    d.maxPct = max(d.maxPct, pct)
                    d.minPct = min(d.minPct, pct)
                }

                switch typeStr {
                case SystemEventType.displayOn.rawValue:
                    if let off = d.lastScreensOff {
                        d.soff += ts - off
                        d.lastScreensOff = nil
                    }
                    d.lastDisplayOn = ts
                case SystemEventType.displayOff.rawValue, SystemEventType.screensSleep.rawValue:
                    if let on = d.lastDisplayOn {
                        d.sot += ts - on
                        d.lastDisplayOn = nil
                    }
                    d.lastScreensOff = ts
                case SystemEventType.screensWake.rawValue:
                    if let off = d.lastScreensOff {
                        d.soff += ts - off
                        d.lastScreensOff = nil
                    }
                    d.lastDisplayOn = ts
                case SystemEventType.systemSleep.rawValue:
                    if let on = d.lastDisplayOn {
                        d.sot += ts - on
                        d.lastDisplayOn = nil
                    }
                    d.lastSleep = ts
                case SystemEventType.systemWake.rawValue:
                    if let sleep = d.lastSleep {
                        d.sleep += ts - sleep
                        d.lastSleep = nil
                    }
                case SystemEventType.acConnected.rawValue, SystemEventType.chargingInterruptionStart.rawValue:
                    d.lastChargeStart = ts
                case SystemEventType.acDisconnected.rawValue, SystemEventType.chargingInterruptionEnd.rawValue:
                    if let start = d.lastChargeStart {
                        d.charging += ts - start
                        d.lastChargeStart = nil
                    }
                    d.cycleCount += 1
                default:
                    break
                }

                dayData[day] = d
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            return dayData.map { day, data in
                let date = dateFormatter.date(from: day) ?? Date()
                return DailySummary(
                    date: date,
                    totalScreenOnTime: data.sot,
                    totalScreenOffTime: data.soff,
                    totalSleepTime: data.sleep,
                    totalBatteryUsed: max(0, data.maxPct - data.minPct),
                    totalChargingDuration: data.charging,
                    dischargeCycleCount: data.cycleCount
                )
            }.sorted { $0.date > $1.date }
        }
    }

    func getTodaySummary() -> DailySummary {
        let summaries = getDailySummaries(days: 1)
        if let today = summaries.first(where: { Calendar.current.isDateInToday($0.date) }) {
            return today
        }
        return DailySummary(date: Date())
    }

    // MARK: - CSV Export

    func exportToCSV(destinationURL: URL) throws {
        try queue.sync {
            let sql = """
            SELECT timestamp, battery_percentage, event_type, metadata
            FROM events ORDER BY timestamp ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw NSError(domain: "BatterySOT.Database", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to prepare export query"])
            }
            defer { sqlite3_finalize(stmt) }

            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: destinationURL) else {
                throw NSError(domain: "BatterySOT.Database", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot open file for writing"])
            }
            defer { try? handle.close() }

            let header = "timestamp,timestamp_iso8601,battery_percent,event_type,metadata\n"
            if let data = header.data(using: .utf8) { handle.write(data) }

            let isoFormatter = ISO8601DateFormatter()

            while sqlite3_step(stmt) == SQLITE_ROW {
                let epoch = sqlite3_column_double(stmt, 0)
                let isoDate = isoFormatter.string(from: Date(timeIntervalSince1970: epoch))
                let pctStr = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? "" : "\(sqlite3_column_int(stmt, 1))"
                let eventType = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 2))
                let metadata = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, 3))

                let line = "\(epoch),\(isoDate),\(pctStr),\(eventType),\"\(metadata.replacingOccurrences(of: "\"", with: "\"\""))\"\n"
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            }
        }
    }

    // MARK: - Reset Controls

    func resetCurrentSession() {
        queue.sync {
            exec("UPDATE discharge_cycles SET is_active = 0 WHERE is_active = 1;")
            exec("UPDATE discharge_segments SET is_active = 0 WHERE is_active = 1;")
            exec("UPDATE charging_interruptions SET is_active = 0 WHERE is_active = 1;")
        }
    }

    func clearAllHistory() {
        queue.sync {
            exec("DELETE FROM events;")
            exec("DELETE FROM discharge_segments;")
            exec("DELETE FROM charging_interruptions;")
            exec("DELETE FROM discharge_cycles;")
            exec("DELETE FROM app_state;")
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        var errorMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMsg) != SQLITE_OK {
            if let errorMsg = errorMsg {
                print("BatterySOT DB Error: \(String(cString: errorMsg))")
                sqlite3_free(errorMsg)
            }
        }
    }
}
