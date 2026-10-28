// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum HubMonitoringTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let metric = try decoder.decode(HubMetric.self, from: Data(#"""
        {
          "collected_at":1700000000,"cpu_percent":18.5,"memory_percent":24,
          "disk_percent":42,"details":{"clock":{
            "system_utc_epoch":1699999835,"timezone":"Europe/Moscow",
            "ntp_synchronized":false,"rtc_local_time":false,
            "rtc_utc_epoch":1700000000,"rtc_offset_seconds":165
          }}
        }
        """#.utf8))
        precondition(metric.collectedAt == 1_700_000_000)
        precondition(metric.details?.clock?.rtcOffsetSeconds == 165)
        precondition(metric.details?.clock?.ntpSynchronized == false)
        let oldMetric = try decoder.decode(HubMetric.self, from: Data(#"{"cpu_percent":8,"details":{}}"#.utf8))
        precondition(oldMetric.details?.clock == nil)

        let checks = try decoder.decode(HubChecksReply.self, from: Data(#"""
        {
          "server_id":"server-1","revision":2,"worker_seen_at":1700000003,
          "checks":[
            {"id":"http-1","name":"Панель","kind":"http","enabled":true,
             "interval_seconds":60,"timeout_seconds":5,"state":"up",
             "latest":{"observed_at":1700000000,"received_at":1700000002,"status":"up",
               "latency_ms":42,"http_status":200,"tls_expires_at":1700500000,"error_code":null}},
            {"id":"tcp-1","name":"SSH","kind":"tcp","enabled":true,
             "interval_seconds":120,"timeout_seconds":3,"state":"stale",
             "latest":{"observed_at":1699999800,"received_at":1699999802,"status":"down",
               "latency_ms":3000,"http_status":null,"tls_expires_at":null,"error_code":"timeout"}},
            {"id":"dns-1","name":"DNS","kind":"dns","enabled":true,
             "interval_seconds":60,"timeout_seconds":5,"state":"down",
             "latest":{"observed_at":1700000000,"received_at":1700000002,"status":"down",
               "latency_ms":9,"http_status":null,"tls_expires_at":null,"error_code":"dns_mismatch"}}
          ]
        }
        """#.utf8))
        precondition(checks.checks.count == 3)
        precondition(checks.checks[0].kind.title == "HTTP/HTTPS")
        precondition(checks.checks[0].latest?.tlsExpiresAt == 1_700_500_000)
        precondition(checks.checks[1].state == .stale)
        precondition(checks.checks[1].latest?.errorTitle == "Таймаут")
        precondition(checks.checks[2].kind.title == "DNS")
        precondition(checks.checks[2].latest?.errorTitle == "DNS вернул другой адрес")

        let history = try decoder.decode(HubCheckHistoryReply.self, from: Data(#"""
        {
          "server_id":"server-1","check_id":"dns-1",
          "results":[
            {"observed_at":1700000000,"received_at":1700000002,"status":"down",
             "latency_ms":9,"http_status":null,"tls_expires_at":null,
             "error_code":"dns_mismatch","host":"private-target.example","answer":"203.0.113.45"},
            {"observed_at":1699999940,"received_at":1699999942,"status":"up",
             "latency_ms":8,"http_status":null,"tls_expires_at":null,"error_code":null}
          ]
        }
        """#.utf8))
        precondition(history.serverId == "server-1" && history.checkId == "dns-1")
        precondition(history.results.count == 2 &&
                     history.results[0].errorTitle == "DNS вернул другой адрес" &&
                     history.results[1].status == .up)

        let filesystem = try decoder.decode(HubFilesystemAlertsReply.self, from: Data(#"""
        {
          "server_id":"11111111-1111-4111-8111-111111111111", "revision":4,
          "hold_seconds":300, "source_status":"ok", "observed_at":1700000050,
          "rules":[{"mountpoint":"/srv/data", "metric":"space", "threshold_percent":85}],
          "filesystems":[{"mountpoint":"/srv/data", "fstype":"ext4",
            "space_used_percent":86.5,"inodes_used_percent":null}],
          "observations":[{"mountpoint":"/srv/data", "metric":"space",
            "status":"alert","used_percent":86.5}]
        }
        """#.utf8))
        precondition(filesystem.rules[0].metric == .space)
        precondition(filesystem.filesystems[0].inodesUsedPercent == nil)
        precondition(filesystem.observations[0].status == .alert)
        let update = HubFilesystemAlertUpdate(revision: filesystem.revision,
            holdSeconds: filesystem.holdSeconds, rules: filesystem.rules)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as! [String: Any]
        precondition(encoded["revision"] as? Int == 4 && encoded["hold_seconds"] as? Int == 300)
        let encodedRules = encoded["rules"] as! [[String: Any]]
        precondition(encodedRules[0]["threshold_percent"] as? Int == 85)
        precondition(encodedRules[0]["mountpoint"] as? String == "/srv/data")
        let duplicate = #"""
        {"server_id":"11111111-1111-4111-8111-111111111111", "revision":4,
         "hold_seconds":300,"source_status":"ok","observed_at":1700000050,
         "rules":[{"mountpoint":"/", "metric":"space", "threshold_percent":85},
                  {"mountpoint":"/", "metric":"space", "threshold_percent":90}],
         "filesystems":[],"observations":[]}
        """#
        do {
            _ = try decoder.decode(HubFilesystemAlertsReply.self, from: Data(duplicate.utf8))
            preconditionFailure("Duplicate filesystem rule accepted")
        } catch is DecodingError { }

        let incident = try decoder.decode(HubIncident.self, from: Data(#"""
        {
          "id":"incident-1","server_id":"server-1","server_name":"Gateway",
          "kind":"check:http-1","subject":"Панель","state":"firing",
          "opened_at":1700000000,"updated_at":1700000100,"resolved_at":null,
          "acknowledged_at":null,"current_value":null,"threshold":null,
          "alerted_at":1700000100
        }
        """#.utf8))
        precondition(incident.title == "Панель" && incident.state == .firing)
        for (kind, subject, title) in [
            ("tls:http-1", "Панель", "Срок сертификата: Панель"),
            ("container:abc123", "database", "Контейнер: database"),
            ("filesystem:space:abc123", "/srv/data", "Мало места: /srv/data"),
            ("filesystem:inodes:abc123", "/srv/data", "Мало inode: /srv/data"),
            ("high_root_inodes", "", "Мало inode на корневом диске")
        ] {
            let raw = #"{"id":"incident-3","server_id":"server-1","server_name":"Gateway","kind":""# + kind +
                #"","subject":""# + subject + #"","state":"firing","opened_at":1700000000,"updated_at":1700000100,"resolved_at":null,"acknowledged_at":null,"current_value":86,"threshold":85,"alerted_at":1700000100}"#
            let typed = try decoder.decode(HubIncident.self, from: Data(raw.utf8))
            precondition(typed.title == title)
        }
        let resolved = try decoder.decode(HubIncident.self, from: Data(#"""
        {
          "id":"incident-2","server_id":"server-1","server_name":"Gateway",
          "kind":"high_cpu","subject":null,"state":"resolved",
          "opened_at":1700000000,"updated_at":1700000400,"resolved_at":1700000400,
          "acknowledged_at":null,"current_value":41.5,"threshold":90,
          "alerted_at":1700000000
        }
        """#.utf8))
        precondition(resolved.title == "Высокая загрузка CPU" && resolved.resolvedAt == 1_700_000_400)

        let utc = HubTime.local(1_700_000_000, in: TimeZone(secondsFromGMT: 0)!)
        let plusThree = HubTime.local(1_700_000_000, in: TimeZone(secondsFromGMT: 10_800)!)
        precondition(utc.contains("2023-11-14 22:13:20"))
        precondition(plusThree.contains("2023-11-15 01:13:20"))
        precondition(HubTime.local(nil) == "—")
        print("Hub monitoring: UTC seconds, checks, filesystem alerts, incidents and RTC diagnostics passed.")
    }
}
