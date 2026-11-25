"""Four offline student journeys on an ordinary APK installed on a disposable AVD.

Disable all network on a fresh Student_Device20_QA_ AVD before installing the
ordinary APK. Run with its emulator serial and the SHA-256 of the installed APK.
No account, SDK test entry point or external backend is used.
"""

import argparse
from datetime import date, timedelta
import re
import subprocess
import time

from qa_android_background_push_materials import Device


PACKAGE = "com.mill453020.studentplatform"


def lines(node):
    return (node.get("content-desc") or node.get("text") or node.get("hint") or "").splitlines()


def bounds(node):
    return tuple(map(int, re.findall(r"\d+", node.get("bounds"))))


class GuestDevice(Device):
    def __init__(self, serial, apk_hash):
        if not re.fullmatch(r"emulator-\d+", serial) or not re.fullmatch(r"[0-9a-f]{64}", apk_hash):
            raise ValueError("Supply a dedicated AVD and the ordinary APK hash")
        self.prefix = ["adb", "-s", serial]
        name = self.run("emu", "avd", "name").decode().splitlines()[0].strip()
        if not name.startswith("Student_Device20_QA_"):
            raise RuntimeError("This suite requires its own disposable AVD")
        self.require_offline()
        package_path = self.run("shell", "pm", "path", PACKAGE).decode().strip()
        if not re.fullmatch(r"package:/data/app/[^\s]+/base\.apk", package_path):
            raise RuntimeError("Install the ordinary standalone APK first")
        installed = self.run("shell", "sha256sum", package_path[len("package:"):]).decode().split()[0]
        if installed != apk_hash:
            raise RuntimeError("Installed APK checksum differs from requested APK")
        print("Android API", self.run("shell", "getprop", "ro.build.version.sdk").decode().strip(),
              "ordinary package", PACKAGE, "sha256", installed, flush=True)

    def require_offline(self):
        if (self.run("shell", "settings", "get", "global", "airplane_mode_on").strip() != b"1"
                or b"Active default network: none" not in self.run("shell", "dumpsys", "connectivity")):
            raise RuntimeError("Disable network before starting the ordinary APK")

    def wait_node(self, predicate, description, *, scroll=False):
        deadline = time.monotonic() + 65
        while time.monotonic() < deadline:
            try:
                nodes = self.nodes(PACKAGE)
                for node in nodes:
                    if predicate(node):
                        return node
                if scroll and nodes:
                    x, y, right, bottom = bounds(nodes[0])
                    mid = (x + right) // 2
                    self.run("shell", "input", "swipe", str(mid), str(y + (bottom-y)*3//4),
                             str(mid), str(y + (bottom-y)//3), "280")
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                pass
            time.sleep(.2)
        raise RuntimeError("Missing Android view: " + description)

    def label(self, value, *, scroll=False):
        return self.wait_node(lambda node: value in lines(node), value, scroll=scroll)

    def click(self, value, *, scroll=False):
        self.tap_node(self.label(value, scroll=scroll))

    def back(self):
        self.run("shell", "input", "keyevent", "KEYCODE_BACK")

    def fresh_home(self):
        self.require_offline()
        self.run("shell", "am", "force-stop", PACKAGE)
        self.run("shell", "rm", "-f", "/data/local/tmp/student-materials-push-qa.xml")
        self.run("shell", "am", "start", "-n", PACKAGE + "/.MainActivity")
        self.label("Войти")


def week_label(day):
    monday = day - timedelta(days=day.weekday())
    sunday = monday + timedelta(days=6)
    return f"{monday.day}.{monday.month}–{sunday.day}.{sunday.month}"


def schedule_week(device):
    device.fresh_home()
    today = date.fromisoformat(device.run("shell", "date", "+%F").decode().strip())
    device.click("Расписание")
    device.click("Действия с расписанием")
    device.click("По неделям")
    current, future = week_label(today), week_label(today + timedelta(days=7))
    device.label(current)
    device.click("Следующая неделя")
    device.label(future)
    device.click("Предыдущая неделя")
    device.label(current)
    device.click("Следующая неделя")
    device.label(future)
    device.click("Действия с расписанием")
    device.click("Текущая неделя")
    device.label(current)
    print(f"PASS week navigation, device calendar {current} -> {future} -> {current}", flush=True)


def obtain_account(device):
    device.fresh_home()
    device.click("Профиль")
    device.click("Продолжить с аккаунтом", scroll=True)
    device.click("Зарегистрироваться", scroll=True)
    device.label("Получить доступ")
    device.label("Самостоятельная регистрация временно недоступна. Для получения аккаунта обратитесь к администратору платформы.")
    if any(n.get("class") == "android.widget.EditText" for n in device.nodes(PACKAGE)):
        raise RuntimeError("Unexpected registration form")
    device.click("Вернуться ко входу")
    device.click("Пока посмотреть приложение", scroll=True)
    device.click("Профиль")
    device.label("Гостевой режим")
    print("PASS account provisioning instructions, back to login, continue as guest", flush=True)


def vacancy_search(device):
    device.fresh_home()
    device.click("База")
    device.click("Выбрать раздел")
    device.click("Вакансии")
    field = device.label("Найти вакансию")
    device.tap_node(field)
    query = "surveying"
    device.run("shell", "input", "text", query)
    device.back()
    device.label("Не удалось загрузить раздел")
    device.click("Повторить")
    device.label("Не удалось загрузить раздел")
    nodes = device.nodes(PACKAGE)
    if (not any(n.get("class") == "android.widget.EditText" and n.get("text") == query for n in nodes)
            or any("По запросу ничего не найдено" in lines(n) for n in nodes)):
        raise RuntimeError("Failed vacancy lookup lost its query or became an empty result")
    device.label("Повторить")
    print("PASS vacancy search and retry without network preserve query and an explicit error", flush=True)


def check_password(device):
    device.fresh_home()
    device.click("Войти")
    def password_field(node):
        return node.get("class") == "android.widget.EditText" and node.get("password") == "true"
    field = device.wait_node(password_field, "masked password field")
    device.tap_node(field)
    sample = "SampleOnly912"
    device.run("shell", "input", "text", sample)
    device.back()
    device.wait_node(password_field, "populated masked field")
    device.click("Показать пароль")
    device.wait_node(lambda n: n.get("class") == "android.widget.EditText" and
                     n.get("password") == "false" and n.get("text") == sample, "revealed input")
    device.click("Скрыть пароль")
    concealed = device.wait_node(password_field, "hidden password after second tap")
    device.label("Показать пароль")
    if sample in "".join(lines(concealed)) or sample == concealed.get("text"):
        raise RuntimeError("Password remained visible after concealment")
    device.click("Пока посмотреть приложение", scroll=True)
    device.click("Профиль")
    device.label("Гостевой режим")
    print("PASS reveal and re-hide sample password, abandon unsubmitted form, retain guest profile", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("serial")
    parser.add_argument("sha256")
    args = parser.parse_args()
    device = GuestDevice(args.serial, args.sha256)
    for journey in (schedule_week, obtain_account, vacancy_search, check_password):
        journey(device)
    device.require_offline()
