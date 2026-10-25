import org.jackhuang.hmcl.auth.offline.Skin;
import org.jackhuang.hmcl.auth.yggdrasil.TextureModel;

public final class SkinLoadCheck {
    public static void main(String[] args)throws Exception {
        System.setProperty("shenggan.headless","true");
        var loaded=new Skin(Skin.Type.LOCAL_FILE,null,TextureModel.WIDE,args[0],null).load("HarborSkinQA").run();
        if(loaded==null||loaded.skin()==null)throw new AssertionError("Original HMCL offline skin pipeline did not load the texture");
        System.out.println("Original HMCL offline skin texture pipeline: PASS");
    }
}
