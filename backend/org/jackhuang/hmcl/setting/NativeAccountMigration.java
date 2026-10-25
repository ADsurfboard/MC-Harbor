package org.jackhuang.hmcl.setting;

import com.google.gson.JsonObject;
import org.jackhuang.hmcl.util.gson.JsonUtils;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

/** Read-only access to the stable HMCL private-data adapter. No plaintext file is written. */
public final class NativeAccountMigration {
    private NativeAccountMigration() {}
    public static Map<String,JsonObject> readPrivateData(Path file)throws IOException {
        if(!Files.isRegularFile(file))return Map.of();
        try(var reader=Files.newBufferedReader(file)){
            AccountPrivateData store=JsonUtils.GSON.fromJson(reader,AccountPrivateData.class);
            Map<String,JsonObject> result=new LinkedHashMap<>();
            if(store!=null)store.getPrivateData().forEach((id,value)->result.put(id.toString(),value));
            return result;
        }
    }
}
