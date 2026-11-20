package org.jackhuang.hmcl.setting;

import com.google.gson.JsonObject;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import org.jackhuang.hmcl.util.gson.JsonUtils;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Read-only access to the stable HMCL private-data adapter. No plaintext file is written. */
public final class NativeAccountMigration {
    private NativeAccountMigration() {}

    /** Converts legacy account rows in memory using HMCL's pinned migration rules. */
    public static LegacyAccounts migrateLegacyAccounts(JsonArray records, boolean userStorage) {
        List<JsonObject> legacy = new ArrayList<>();
        for (JsonElement record : records) {
            if (record.isJsonObject()) legacy.add(record.getAsJsonObject().deepCopy());
        }
        LegacyConfigMigrator.AccountMigrationResult migrated = LegacyConfigMigrator.migrateLegacyAccounts(legacy, userStorage);
        Map<String,JsonObject> secrets = new LinkedHashMap<>();
        migrated.privateData().getPrivateData().forEach((id,value) -> secrets.put(id.toString(), value.deepCopy()));
        List<JsonObject> metadata = new ArrayList<>();
        migrated.metadata().getAccounts().forEach(account -> metadata.add(account.deepCopy()));
        return new LegacyAccounts(List.copyOf(metadata), Map.copyOf(secrets));
    }

    public static Map<String,JsonObject> readPrivateData(Path file)throws IOException {
        if(!Files.isRegularFile(file, java.nio.file.LinkOption.NOFOLLOW_LINKS))return Map.of();
        if (Files.size(file) > 16_000_000) throw new IOException("Private account file too large");
        try(var reader=Files.newBufferedReader(file)){
            AccountPrivateData store=JsonUtils.GSON.fromJson(reader,AccountPrivateData.class);
            Map<String,JsonObject> result=new LinkedHashMap<>();
            if(store!=null)store.getPrivateData().forEach((id,value)->result.put(id.toString(),value));
            return result;
        }
    }

    public record LegacyAccounts(List<JsonObject> metadata, Map<String,JsonObject> privateData) {}
}
