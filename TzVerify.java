import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.zone.ZoneRulesProvider;

/**
 * Proves a patched image is correct. Compiled at release 8 so it runs on any
 * JDK 8+ image, JRE-only images included.
 *
 * args: <expected tzdb version> <zone> <year> <expected november offset> <min zone count>
 * Exits non-zero with a readable message when any expectation is not met.
 */
public class TzVerify {

    public static void main(String[] args) {
        String wantDb = args.length > 0 ? args[0] : "";
        String zoneId = args.length > 1 ? args[1] : "America/Edmonton";
        int year = args.length > 2 ? Integer.parseInt(args[2]) : 2026;
        String wantNov = args.length > 3 ? args[3] : "";
        int minZones = args.length > 4 ? Integer.parseInt(args[4]) : 0;

        String db;
        try {
            db = ZoneRulesProvider.getVersions("UTC").lastKey();
        } catch (Exception e) {
            db = "?";
        }
        int zones = ZoneRulesProvider.getAvailableZoneIds().size();
        ZoneId z = ZoneId.of(zoneId);
        String oct = ZonedDateTime.of(year, 10, 15, 12, 0, 0, 0, z).getOffset().toString();
        String nov = ZonedDateTime.of(year, 11, 15, 12, 0, 0, 0, z).getOffset().toString();
        String jan = ZonedDateTime.of(year, 1, 15, 12, 0, 0, 0, z).getOffset().toString();

        System.out.println("tzdb=" + db + " zones=" + zones + " " + zoneId
                + " jan=" + jan + " oct=" + oct + " nov=" + nov
                + (oct.equals(nov) ? " (no autumn change)" : " (falls back)"));

        StringBuilder bad = new StringBuilder();
        if (!wantDb.isEmpty() && !wantDb.equals(db)) {
            bad.append("  tzdb is ").append(db).append(", expected ").append(wantDb).append('\n');
        }
        if (!wantNov.isEmpty() && !wantNov.equals(nov)) {
            bad.append("  november offset is ").append(nov).append(", expected ").append(wantNov).append('\n');
        }
        if (minZones > 0 && zones < minZones) {
            bad.append("  zone count dropped to ").append(zones)
               .append(", expected at least ").append(minZones)
               .append(" - zone ids were lost\n");
        }
        // a zone that resolves to a fixed offset means the id was not found at all
        try {
            ZoneId.of("SystemV/MST7");
        } catch (Exception e) {
            bad.append("  SystemV/MST7 is gone - jdk11_backward was not compiled in\n");
        }
        if (bad.length() > 0) {
            System.err.println("VERIFY FAILED:");
            System.err.print(bad);
            System.exit(1);
        }
        System.out.println("VERIFY OK");
    }
}
