package qa.ordinary;

import android.graphics.Rect;
import android.os.SystemClock;
import com.android.uiautomator.core.Configurator;
import com.android.uiautomator.core.UiObject;
import com.android.uiautomator.core.UiSelector;
import com.android.uiautomator.testrunner.UiAutomatorTestCase;

public class ForegroundBannerProbe extends UiAutomatorTestCase {
    public void testBanner() throws Exception {
        Configurator.getInstance().setWaitForIdleTimeout(30).setWaitForSelectorTimeout(100);
        String marker = getParams().getString("marker");
        String action = getParams().getString("action");
        assertTrue("Expected a synthetic message marker", marker != null && !marker.isEmpty());
        boolean absent = "absent".equals(action);
        assertTrue("Expected tap, dismiss or absent", absent || "tap".equals(action) || "dismiss".equals(action));
        UiSelector app = new UiSelector().packageName("com.mill453020.studentplatform.offlinefixture");
        UiObject text = new UiObject(app.descriptionContains(marker));
        UiObject open = new UiObject(app.description("Открыть"));
        long deadline = SystemClock.elapsedRealtime() + (absent ? 21000 : 30000);
        while (SystemClock.elapsedRealtime() < deadline) {
            if (text.exists() && open.exists()) {
                // Flutter sometimes merges the banner's message into a full-screen
                // semantics node. The visible button has the actual touch bounds.
                Rect button = open.getVisibleBounds();
                if (button.height() > 0 && button.top >= 0
                        && button.bottom < getUiDevice().getDisplayHeight() / 3) {
                    assertFalse("Unexpected banner above active conversation", absent);
                    SystemClock.sleep(320);
                    button = open.getVisibleBounds();
                    assertFalse("Banner button still visible", button.isEmpty());
                    System.out.println("Gesture uptime ms=" + SystemClock.elapsedRealtime()
                            + " button=" + button.toShortString());
                    if ("tap".equals(action)) {
                        assertTrue("Tap delivered", getUiDevice().click(button.centerX(), button.centerY()));
                    } else {
                        assertTrue("Swipe delivered", getUiDevice().swipe(
                                button.centerX(), button.centerY(), button.centerX(), 0, 10));
                        SystemClock.sleep(500);
                        assertFalse("Banner was dismissed", open.exists());
                    }
                    System.out.println("observed banner " + action);
                    return;
                }
            }
            SystemClock.sleep(50);
        }
        assertTrue("Targeted foreground banner never appeared", absent);
        System.out.println("observed banner absent");
    }
}
