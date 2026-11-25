"""Three journeys on the ordinary offline APK and two in the ordinary UI with local Android login.

guest SERIAL SHA256 expects the release APK. settings SERIAL PUBLIC_CA expects
the debug ordinary_android_loopback_main.dart build, adb reverse and local Docker
gateway. Both modes require a disposable, disconnected Student_Device20_QA_ AVD.
"""
import argparse
from contextlib import contextmanager
from datetime import date, timedelta
from io import BytesIO
from pathlib import Path
from secrets import token_hex
from uuid import UUID

from PIL import Image

from qa_android_background_push_materials import Device, PACKAGE as LOCAL_PACKAGE
from qa_android_ordinary_guest import GuestDevice, bounds, lines, week_label
from qa_android_portrait import frame


def portrait(device):
    width, height, _ = frame(device)
    if width >= height:
        raise AssertionError(f"Expected portrait, got {width} x {height}")


def choose_month_day(device):
    months = "Январь Февраль Март Апрель Май Июнь Июль Август Сентябрь Октябрь Ноябрь Декабрь".split()
    device.fresh_home()
    portrait(device)
    today = date.fromisoformat(device.run("shell", "date", "+%F").decode().strip())
    target = (today.replace(day=28) + timedelta(days=5)).replace(day=17)
    heading = f"{months[target.month - 1]} {target.year}"
    device.click("Расписание")
    device.click("Выбрать дату")
    device.click("Следующий месяц")
    device.label(heading)
    for direction, year in [("Следующий месяц", target.year + 1),
                            ("Предыдущий месяц", target.year)]:
        x, y, right, bottom = bounds(device.label(direction))
        cx, cy = str((x + right) // 2), str((y + bottom) // 2)
        device.run("shell", "input", "swipe", cx, cy, cx, cy, "850")
        device.label(f"{months[target.month - 1]} {year}")
    device.click(str(target.day))
    device.label(heading)
    weekdays = ("ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС")

    def day_node(day):
        return device.wait_node(lambda n: weekdays[day.weekday()] in lines(n) and
                                str(day.day) in lines(n), "calendar day " + str(day))

    def accent_fraction(image, node):
        colors = image.crop(bounds(node)).convert("RGB")
        pixels = colors.width * colors.height
        return sum(count for count, rgb in colors.getcolors(pixels) if max(rgb) - min(rgb) > 45) / pixels

    selected = day_node(target)
    adjacent = day_node(target + timedelta(days=1 if target.weekday() < 6 else -1))
    shot = Image.open(BytesIO(device.run("exec-out", "screencap", "-p")))
    if accent_fraction(shot, selected) <= accent_fraction(shot, adjacent) + .10:
        raise AssertionError("The chosen date is not visibly selected in the schedule")
    device.click("Действия с расписанием")
    device.click("По неделям")
    device.label(week_label(target))
    print(f"PASS monthly date picker: {target} in {week_label(target)}", flush=True)


def retry_campus_map(device, screenshot=None):
    device.fresh_home()
    device.click("Профиль")
    device.click("Карта СПБГАСУ", scroll=True)
    device.label("Не удалось загрузить карту")
    device.click("Повторить")
    device.label("Не удалось загрузить карту")
    device.label("Проверь подключение к интернету.")
    if screenshot is not None:
        screenshot.write_bytes(device.run("exec-out", "screencap", "-p"))
    device.back()
    device.label("Карта СПБГАСУ", scroll=True)
    device.label("Профиль")
    print("PASS offline campus map, retry and return to guest profile", flush=True)


def guest_messages(device):
    device.fresh_home()
    device.click("Профиль")
    device.click("Сообщения")
    device.label("Больше возможностей")
    device.click("Войти", scroll=True)
    device.label("С возвращением")
    device.click("Пока посмотреть приложение", scroll=True)
    device.click("Профиль")
    device.label("Гостевой режим")
    print("PASS guest messages require login, abandoning login restores guest access", flush=True)


class SettingsDevice(GuestDevice):
    app_package = LOCAL_PACKAGE

    def __init__(self, serial, ca):
        Device.__init__(self, serial, avd_prefix="Student_Device20_QA_")
        self.require_offline()
        certificate = ca.read_bytes()
        if b"BEGIN CERTIFICATE" not in certificate or b"PRIVATE KEY" in certificate:
            raise ValueError("A public local gateway CA is required")
        self.run("reverse", "tcp:55443", "tcp:55443")
        self.run("shell", "pm", "clear", LOCAL_PACKAGE)
        self.run("shell", "run-as", LOCAL_PACKAGE, "mkdir", "-p", "files")
        self.write_private("ordinary_test_ca.pem", certificate)

    def edit_profile(self):
        def open_profile(node):
            label = lines(node)
            if "Редактировать" in label:
                return True
            if "Не сейчас" in label or (
                    "Профиль" in label and any("Вкладка" in line for line in label)):
                self.tap_node(node)
            return False

        self.wait_node(open_profile, "authenticated profile")
        self.click("Редактировать")
        self.label("Настройки профиля")

    def theme_row(self, value):
        return self.wait_node(lambda node: "Тема" in lines(node) and value in lines(node),
                              "theme preference " + value, scroll=True)

    def dark_fraction(self):
        image = Image.open(BytesIO(self.run("exec-out", "screencap", "-p"))).convert("L")
        w, h = image.size
        histogram = image.crop((w // 8, h // 4, w * 7 // 8, h * 3 // 4)).histogram()
        return sum(histogram[:80]) / sum(histogram)


@contextmanager
def local_student():
    from local_e2e_api import request, sql
    login = "e2e_settings_" + token_hex(6)
    email, password = login + "@student.local", token_hex(16)
    code, result = request("/auth/v1/admin/users", {
        "email": email, "password": password, "email_confirm": True}, admin=True)
    if code not in (200, 201):
        raise RuntimeError("Could not create a local settings student")
    uid = str(UUID(result["id"]))
    try:
        sql(f"""insert into public.users(id,login,name,surname)
             values ('{uid}','{login}','QA','Settings')
             on conflict(id) do update set login=excluded.login;""")
        yield login, password
    finally:
        endpoint = "/auth/v1/admin/users/" + uid
        code, user = request(endpoint, admin=True)
        if code != 200 or user.get("email") != email:
            raise RuntimeError("Local settings account identity changed")
        if request(endpoint, method="DELETE", admin=True)[0] not in (200, 204):
            raise RuntimeError("Local settings account deletion failed")
        sql(f"delete from public.users where id='{uid}' and login='{login}';")
        if request(endpoint, admin=True)[0] != 404:
            raise RuntimeError("Local settings account survived cleanup")
        print("Removed local Android settings student", flush=True)


def saved_theme(device):
    device.edit_profile()
    default = "Как на устройстве"
    device.tap_node(device.theme_row(default))
    device.click("Светлая")
    device.theme_row("Светлая")
    light = device.dark_fraction()
    device.click("Тема")
    device.click("Тёмная")
    device.theme_row("Тёмная")
    device.run("shell", "am", "force-stop", LOCAL_PACKAGE)
    device.start()
    device.edit_profile()
    device.theme_row("Тёмная")
    dark = device.dark_fraction()
    if dark - light < .40:
        raise AssertionError(f"Saved theme did not change visible colors ({light:.2f}, {dark:.2f})")
    device.click("Тема")
    device.click(default)
    device.theme_row(default)
    print(f"PASS theme survives process restart; rendered dark pixels {light:.0%} -> {dark:.0%}", flush=True)


def cache_limit(device):
    def limit(value):
        device.wait_node(lambda n: any("Целевой лимит учтённого серверного кэша — " +
                         value + " МБ" in line for line in lines(n)), "cache quota " + value)

    device.click("Данные приложения", scroll=True)
    limit("500.0")
    device.click("Изменить целевой лимит")
    device.click("250 МБ")
    limit("250.0")
    device.click("Очистить кэш публичных новостей", scroll=True)
    device.label("Удалить копии изображений новостей?")
    device.click("Отмена")
    device.back()
    device.click("Данные приложения", scroll=True)
    limit("250.0")
    device.click("Изменить целевой лимит")
    device.click("500 МБ")
    limit("500.0")
    print("PASS quota 500 -> 250 MB, cancel news cleanup, reopen and restore 500 MB", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    guest = sub.add_parser("guest")
    guest.add_argument("serial")
    guest.add_argument("sha256")
    guest.add_argument("--map-screenshot", type=Path)
    settings = sub.add_parser("settings")
    settings.add_argument("serial")
    settings.add_argument("ca", type=Path)
    args = parser.parse_args()
    if args.mode == "guest":
        device = GuestDevice(args.serial, args.sha256)
        choose_month_day(device)
        retry_campus_map(device, args.map_screenshot)
        guest_messages(device)
    else:
        from qa_android_ordinary_chat import enter
        device = SettingsDevice(args.serial, args.ca)
        with local_student() as (login, password):
            try:
                device.start()
                portrait(device)
                device.click("Войти")
                device.label("С возвращением")
                enter(device, 0, login)
                enter(device, 1, password, password=True)
                device.back()
                device.click("Войти")
                saved_theme(device)
                cache_limit(device)
            finally:
                device.run("shell", "am", "force-stop", LOCAL_PACKAGE)
                device.run("reverse", "--remove", "tcp:55443")
    device.require_offline()
