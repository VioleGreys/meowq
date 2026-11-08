// Минимальная замена apksigner (sign/verify) поверх библиотеки Google apksig.
// Понимает аргументы, которые передаёт экспорт Godot 4.3. Только схема v2:
// v1 в apksig 2.3.0 требует внутренних классов старой Java; APK — для Android 7+.
import com.android.apksig.ApkSigner;
import com.android.apksig.ApkVerifier;
import java.io.File;
import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.KeyStore;
import java.security.PrivateKey;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class MiniApkSigner {
	public static void main(String[] args) throws Exception {
		if (args.length == 0) {
			System.err.println("usage: sign|verify ...");
			System.exit(2);
		}
		String ks = null, pass = null, alias = null, keyPass = null, out = null, apk = null;
		int minSdk = 21;
		for (int i = 1; i < args.length; i++) {
			String a = args[i];
			switch (a) {
				case "--ks": ks = args[++i]; break;
				case "--ks-pass": pass = args[++i]; break;
				case "--key-pass": keyPass = args[++i]; break;
				case "--ks-key-alias": alias = args[++i]; break;
				case "--out": out = args[++i]; break;
				case "--min-sdk-version": minSdk = Integer.parseInt(args[++i]); break;
				case "--verbose": case "-v": break;
				default:
					if (a.startsWith("--")) { i++; break; }   // незнакомый ключ со значением
					apk = a;
			}
		}
		if (apk == null) { System.err.println("no apk"); System.exit(2); }
		if (args[0].equals("verify")) {
			ApkVerifier.Result r = new ApkVerifier.Builder(new File(apk)).setMinCheckedPlatformVersion(24).build().verify();
			System.out.println("Verifies: " + r.isVerified() + " (v1 " + r.isVerifiedUsingV1Scheme() + ", v2 " + r.isVerifiedUsingV2Scheme() + ")");
			System.exit(r.isVerified() ? 0 : 1);
		}
		String pw = pass.startsWith("pass:") ? pass.substring(5) : pass;
		String kpw = keyPass == null ? pw : (keyPass.startsWith("pass:") ? keyPass.substring(5) : keyPass);
		KeyStore store = KeyStore.getInstance(KeyStore.getDefaultType());
		try (FileInputStream in = new FileInputStream(ks)) { store.load(in, pw.toCharArray()); }
		if (alias == null) alias = store.aliases().nextElement();
		PrivateKey key = (PrivateKey) store.getKey(alias, kpw.toCharArray());
		List<X509Certificate> chain = new ArrayList<>();
		for (Certificate c : store.getCertificateChain(alias)) chain.add((X509Certificate) c);
		ApkSigner.SignerConfig sc = new ApkSigner.SignerConfig.Builder("CERT", key, chain).build();
		File input = new File(apk);
		File output = out != null ? new File(out) : new File(apk + ".signed.tmp");
		new ApkSigner.Builder(Collections.singletonList(sc)).setInputApk(input).setOutputApk(output)
				.setMinSdkVersion(Math.max(minSdk, 24)).setV1SigningEnabled(false).setV2SigningEnabled(true).build().sign();
		if (out == null) Files.move(output.toPath(), input.toPath(), StandardCopyOption.REPLACE_EXISTING);
		System.out.println("Signed");
	}
}
