package qa.ordinary;

import android.os.SystemClock;
import com.android.uiautomator.core.Configurator;
import com.android.uiautomator.core.UiObject;
import com.android.uiautomator.core.UiSelector;
import com.android.uiautomator.testrunner.UiAutomatorTestCase;

/** Observe the transient error in Android's accessibility tree while submitting. */
public class OrdinaryLoginProbe extends UiAutomatorTestCase {
    public void testWrongPassword() throws Exception {
        Configurator.getInstance().setWaitForIdleTimeout(50).setWaitForSelectorTimeout(150);
        UiSelector app = new UiSelector().packageName("com.mill453020.studentplatform.offlinefixture");
        UiObject button = new UiObject(app.description("Войти"));
        if (!button.exists()) {
            button = new UiObject(app.text("Войти"));
        }
        assertTrue("Login button", button.click());
        String expected = "Неверный логин или пароль.";
        UiObject label = new UiObject(app.descriptionContains(expected));
        UiObject text = new UiObject(app.textContains(expected));
        long deadline = SystemClock.uptimeMillis() + 10000;
        while (SystemClock.uptimeMillis() < deadline) {
            if (label.exists() || text.exists()) {
                return;
            }
            SystemClock.sleep(50);
        }
        fail("The localized invalid credentials message was not visible");
    }
}
