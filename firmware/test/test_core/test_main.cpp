// Host tests for the hardware-independent firmware sources: pio test -e native.
// Protocol cases come from protocol/fixtures, which the apps test against as well.

#include <ArduinoJson.h>
#include <unity.h>

#include <math.h>

#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "effects.h"
#include "model.h"
#include "realtime.h"
#include "render.h"

namespace {

JsonDocument fixture(const char* name) {
  std::ifstream file(std::string(LB_FIXTURES_DIR) + "/" + name);
  std::stringstream text;
  text << file.rdbuf();
  JsonDocument doc;
  TEST_ASSERT_FALSE_MESSAGE(text.str().empty(), name);
  TEST_ASSERT_FALSE_MESSAGE(deserializeJson(doc, text.str()), name);
  return doc;
}

std::vector<uint8_t> unhex(const char* s) {
  std::vector<uint8_t> out;
  for (size_t i = 0; s && s[i] && s[i + 1]; i += 2) {
    out.push_back(static_cast<uint8_t>(std::stoi(std::string(s + i, 2), nullptr, 16)));
  }
  return out;
}

std::string dump(JsonVariantConst v) {
  std::string out;
  serializeJson(v, out);
  return out;
}

// Deep comparison. Numbers compare by value, so 2.2 parsed as float equals 2.2 as double.
bool jsonEqual(JsonVariantConst a, JsonVariantConst b) {
  if (a.is<JsonObjectConst>()) {
    JsonObjectConst oa = a, ob = b.as<JsonObjectConst>();
    if (ob.isNull() || oa.size() != ob.size()) return false;
    for (JsonPairConst kv : oa) {
      if (!jsonEqual(kv.value(), ob[kv.key()])) return false;
    }
    return true;
  }
  if (a.is<JsonArrayConst>()) {
    JsonArrayConst aa = a, ab = b.as<JsonArrayConst>();
    if (ab.isNull() || aa.size() != ab.size()) return false;
    for (size_t i = 0; i < aa.size(); i++) {
      if (!jsonEqual(aa[i], ab[i])) return false;
    }
    return true;
  }
  if (a.is<double>() && b.is<double>()) return fabs(a.as<double>() - b.as<double>()) < 1e-6;
  return a == b;
}

void assertJsonEqual(JsonVariantConst expected, JsonVariantConst actual, const char* what) {
  if (!jsonEqual(expected, actual)) {
    const std::string message = std::string(what) + ": expected " + dump(expected) + ", got " + dump(actual);
    TEST_FAIL_MESSAGE(message.c_str());
  }
}

DeviceConfig plainConfig(uint16_t n) {
  DeviceConfig c;
  c.ledCount = n;
  c.colorOrder = 0;  // RGB
  c.whiteBalance = {255, 255, 255};
  c.dither = false;
  c.maxCurrentMa = 0;
  return c;
}

const uint8_t kFrame[] = {0x41, 0x01, 0x0B, 0x01, 0, 0, 0, 0, 0x00, 0x03, 10, 20, 30};
constexpr uint32_t kSender = 0x2A01A8C0;  // 192.168.1.42
constexpr uint32_t kOther = 0x2B01A8C0;

}  // namespace

void setUp() {}
void tearDown() {}

// Protocol fixtures

void test_effects_match_fixture() {
  JsonDocument doc;
  writeEffects(doc.to<JsonArray>());
  assertJsonEqual(fixture("effects.json").as<JsonVariantConst>(), doc.as<JsonVariantConst>(), "effects");
}

void test_default_state_matches_fixture() {
  JsonDocument doc;
  writeState(doc.to<JsonObject>(), LightState(), 0, nullptr);
  assertJsonEqual(fixture("state.json").as<JsonVariantConst>(), doc.as<JsonVariantConst>(), "state");
}

void test_default_config_matches_fixture() {
  JsonDocument doc;
  writeConfig(doc.to<JsonObject>(), DeviceConfig(), false);
  assertJsonEqual(fixture("config.json").as<JsonVariantConst>(), doc.as<JsonVariantConst>(), "config");
}

void test_state_patches() {
  JsonDocument doc = fixture("state_patches.json");
  LightState base;
  StatePatchResult result;
  ApiError err;
  TEST_ASSERT_TRUE(patchState(doc["base"], base, result, err));

  for (JsonObjectConst c : doc["cases"].as<JsonArrayConst>()) {
    const char* name = c["name"];
    LightState s = base;
    ApiError e;
    const bool ok = patchState(c["patch"], s, result, e);
    TEST_ASSERT_EQUAL_MESSAGE(c["valid"].as<bool>(), ok, name);
    if (ok) {
      JsonDocument out;
      writeState(out.to<JsonObject>(), s, 0, nullptr);
      for (JsonPairConst kv : c["expect"].as<JsonObjectConst>()) {
        assertJsonEqual(kv.value(), out[kv.key()], name);
      }
      TEST_ASSERT_EQUAL_MESSAGE(!c["patch"]["mode"].isNull(), result.hasMode, name);
      TEST_ASSERT_EQUAL_MESSAGE(s != base, result.changed, name);
    } else {
      TEST_ASSERT_TRUE_MESSAGE(s == base, name);
      if (!c["field"].isNull()) TEST_ASSERT_EQUAL_STRING_MESSAGE(c["field"].as<const char*>(), e.field, name);
    }
  }
}

void test_config_patches() {
  JsonDocument doc = fixture("config_patches.json");
  for (JsonObjectConst c : doc["cases"].as<JsonArrayConst>()) {
    const char* name = c["name"];
    const DeviceConfig running;
    DeviceConfig config;
    ApiError e;
    const bool ok = patchConfig(c["patch"], config, e);
    TEST_ASSERT_EQUAL_MESSAGE(c["valid"].as<bool>(), ok, name);
    if (ok) {
      TEST_ASSERT_EQUAL_MESSAGE(c["reboot_required"].as<bool>(), rebootRequired(config, running), name);
      JsonDocument out;
      writeConfig(out.to<JsonObject>(), config, false);
      for (JsonPairConst kv : c["expect"].as<JsonObjectConst>()) {
        assertJsonEqual(kv.value(), out[kv.key()], name);
      }
    } else {
      TEST_ASSERT_EQUAL_STRING_MESSAGE(running.name, config.name, name);
      TEST_ASSERT_EQUAL_MESSAGE(running.ledCount, config.ledCount, name);
      TEST_ASSERT_EQUAL_STRING_MESSAGE(c["field"].as<const char*>(), e.field, name);
    }
  }
}

void test_ddp_packets() {
  JsonDocument doc = fixture("ddp.json");
  for (JsonObjectConst c : doc["cases"].as<JsonArrayConst>()) {
    const char* name = c["name"];
    Realtime rt;
    rt.begin(c["led_count"]);
    const std::vector<uint8_t> packet = unhex(c["packet"]);
    rt.receive(kSender, packet.data(), packet.size(), true, 1000);
    const bool shown = c["shown"];
    TEST_ASSERT_EQUAL_MESSAGE(shown, rt.active(1000), name);
    if (shown) {
      const std::vector<uint8_t> frame = unhex(c["frame"]);
      TEST_ASSERT_EQUAL_HEX8_ARRAY_MESSAGE(frame.data(), rt.frame(), frame.size(), name);
    }
  }
}

// State model

void test_unchanged_values_do_not_count_as_change() {
  LightState s;
  StatePatchResult result;
  ApiError err;
  JsonDocument doc;
  doc["brightness"] = s.brightness;
  doc["mode"] = "solid";
  TEST_ASSERT_TRUE(patchState(doc.as<JsonVariantConst>(), s, result, err));
  TEST_ASSERT_FALSE(result.changed);
  TEST_ASSERT_TRUE(result.hasMode);
  TEST_ASSERT_EQUAL_UINT16(400, result.transitionMs);
}

// Realtime rules

void test_realtime_times_out() {
  Realtime rt;
  rt.begin(1);
  rt.receive(kSender, kFrame, sizeof kFrame, true, 1000);
  TEST_ASSERT_TRUE(rt.active(1000));
  TEST_ASSERT_TRUE(rt.active(1000 + 2499));
  TEST_ASSERT_FALSE(rt.active(1000 + 2500));
  TEST_ASSERT_EQUAL_UINT32(kSender, rt.source());
}

void test_realtime_ignored_while_off() {
  Realtime rt;
  rt.begin(1);
  rt.receive(kSender, kFrame, sizeof kFrame, false, 1000);
  TEST_ASSERT_FALSE(rt.active(1000));
}

void test_realtime_end_blocks_sender_until_it_pauses() {
  Realtime rt;
  rt.begin(1);
  rt.receive(kSender, kFrame, sizeof kFrame, true, 1000);
  rt.end(1100);
  TEST_ASSERT_FALSE(rt.active(1100));
  rt.receive(kSender, kFrame, sizeof kFrame, true, 1200);  // in flight
  TEST_ASSERT_FALSE(rt.active(1200));
  rt.receive(kSender, kFrame, sizeof kFrame, true, 2100);  // still sending: block extends
  TEST_ASSERT_FALSE(rt.active(2100));
  rt.receive(kSender, kFrame, sizeof kFrame, true, 3200);  // after a 1.1 s pause
  TEST_ASSERT_TRUE(rt.active(3200));
}

void test_realtime_end_does_not_block_other_senders() {
  Realtime rt;
  rt.begin(1);
  rt.receive(kSender, kFrame, sizeof kFrame, true, 1000);
  rt.end(1100);
  rt.receive(kOther, kFrame, sizeof kFrame, true, 1200);
  TEST_ASSERT_TRUE(rt.active(1200));
  TEST_ASSERT_EQUAL_UINT32(kOther, rt.source());
}

void test_realtime_end_without_stream_blocks_nothing() {
  Realtime rt;
  rt.begin(1);
  rt.end(1000);
  rt.receive(kSender, kFrame, sizeof kFrame, true, 1100);
  TEST_ASSERT_TRUE(rt.active(1100));
}

void test_realtime_most_recent_sender_wins() {
  Realtime rt;
  rt.begin(1);
  rt.receive(kSender, kFrame, sizeof kFrame, true, 1000);
  rt.receive(kOther, kFrame, sizeof kFrame, true, 1010);
  TEST_ASSERT_EQUAL_UINT32(kOther, rt.source());
}

// Output pipeline

void test_pipeline_zero_brightness_is_black() {
  Pipeline p;
  DeviceConfig c = plainConfig(3);
  c.dither = true;
  p.configure(c);
  const Rgb16 frame[3] = {{65535, 65535, 65535}, {30000, 20000, 10000}, {1, 1, 1}};
  uint8_t out[9];
  p.process(frame, 0, out);
  const uint8_t black[9] = {};
  TEST_ASSERT_EQUAL_HEX8_ARRAY(black, out, 9);
}

void test_pipeline_full_white_is_full_output() {
  Pipeline p;
  p.configure(plainConfig(2));
  const Rgb16 frame[2] = {{65535, 65535, 65535}, {65535, 65535, 65535}};
  uint8_t out[6];
  p.process(frame, 65535, out);
  const uint8_t white[6] = {255, 255, 255, 255, 255, 255};
  TEST_ASSERT_EQUAL_HEX8_ARRAY(white, out, 6);
}

void test_pipeline_gamma_is_monotonic() {
  Pipeline p;
  p.configure(plainConfig(1));
  uint8_t previous = 0;
  for (uint32_t v = 0; v <= 65535; v += 257) {
    const Rgb16 frame = {static_cast<uint16_t>(v), 0, 0};
    uint8_t out[3];
    p.process(&frame, 65535, out);
    TEST_ASSERT_TRUE(out[0] >= previous);
    previous = out[0];
  }
  const Rgb16 grey = {32768, 32768, 32768};  // 50 % sRGB is about 22 % linear
  uint8_t out[3];
  p.process(&grey, 65535, out);
  TEST_ASSERT_UINT8_WITHIN(1, 56, out[0]);
}

void test_pipeline_white_balance() {
  Pipeline p;
  DeviceConfig c = plainConfig(1);
  c.whiteBalance = {255, 128, 0};
  p.configure(c);
  const Rgb16 frame = {65535, 65535, 65535};
  uint8_t out[3];
  p.process(&frame, 65535, out);
  TEST_ASSERT_EQUAL_UINT8(255, out[0]);
  TEST_ASSERT_EQUAL_UINT8(128, out[1]);
  TEST_ASSERT_EQUAL_UINT8(0, out[2]);
}

void test_pipeline_current_limit() {
  Pipeline p;
  DeviceConfig c = plainConfig(43);
  c.maxCurrentMa = 500;
  p.configure(c);
  Rgb16 frame[43];
  for (Rgb16& led : frame) led = {65535, 65535, 65535};
  uint8_t out[43 * 3];
  p.process(frame, 65535, out);
  TEST_ASSERT_TRUE(p.currentMa() <= 500);
  TEST_ASSERT_TRUE(out[0] < 255);

  c.maxCurrentMa = 5000;  // above the 2623 mA this frame draws: unchanged
  p.configure(c);
  p.process(frame, 65535, out);
  TEST_ASSERT_EQUAL_UINT8(255, out[0]);
  TEST_ASSERT_EQUAL_UINT32(43 * 3 * 20 + 43, p.currentMa());
}

void test_pipeline_dither_averages_to_the_16_bit_value() {
  Pipeline p;
  DeviceConfig c = plainConfig(1);
  c.dither = true;
  c.gamma = 1.0f;
  p.configure(c);
  const uint16_t v = 100 * 257 + 128;  // between output steps 100 and 101
  const Rgb16 frame = {v, v, v};
  uint32_t sum = 0;
  for (int i = 0; i < 256; i++) {
    uint8_t out[3];
    p.process(&frame, 65535, out);
    sum += out[0];
  }
  TEST_ASSERT_FLOAT_WITHIN(0.02f, v * 255.0f / 65535.0f, sum / 256.0f);
}

void test_pipeline_black_channel_stays_black_with_dither() {
  Pipeline p;
  DeviceConfig c = plainConfig(1);
  c.dither = true;
  p.configure(c);
  const Rgb16 frame = {20000, 0, 300};
  for (int i = 0; i < 64; i++) {
    uint8_t out[3];
    p.process(&frame, 65535, out);
    TEST_ASSERT_EQUAL_UINT8(0, out[1]);
  }
}

void test_pipeline_reverse_and_color_order() {
  Pipeline p;
  DeviceConfig c = plainConfig(2);
  c.colorOrder = 2;  // GRB
  c.reverse = true;
  p.configure(c);
  const Rgb16 frame[2] = {{65535, 0, 0}, {0, 0, 0}};  // logical LED 0 red
  uint8_t out[6];
  p.process(frame, 65535, out);
  const uint8_t expected[6] = {0, 0, 0, 0, 255, 0};  // physical LED 1, green byte first
  TEST_ASSERT_EQUAL_HEX8_ARRAY(expected, out, 6);
}

// Composition

void test_boot_fades_in() {
  Compositor comp;
  LightState s;
  comp.begin(1, s, 1000);
  comp.render(s, 400, nullptr, 1000);
  TEST_ASSERT_EQUAL_UINT16(0, comp.brightness());
  comp.render(s, 400, nullptr, 1400);
  TEST_ASSERT_UINT16_WITHIN(100, s.brightness * 257 / 2, comp.brightness());
  comp.render(s, 400, nullptr, 1800);
  TEST_ASSERT_EQUAL_UINT16(s.brightness * 257, comp.brightness());
}

void test_crossfade_endpoints_are_exact() {
  Compositor comp;
  LightState s;
  s.color = {255, 0, 0};
  comp.begin(1, s, 0);
  comp.render(s, 400, nullptr, 1000);
  s.color = {0, 0, 255};
  comp.render(s, 400, nullptr, 2000);
  TEST_ASSERT_EQUAL_UINT16(65535, comp.frame()[0].r);
  TEST_ASSERT_EQUAL_UINT16(0, comp.frame()[0].b);
  comp.render(s, 400, nullptr, 2200);
  TEST_ASSERT_TRUE(comp.frame()[0].r > 0 && comp.frame()[0].b > 0);
  comp.render(s, 400, nullptr, 2400);
  TEST_ASSERT_EQUAL_UINT16(0, comp.frame()[0].r);
  TEST_ASSERT_EQUAL_UINT16(65535, comp.frame()[0].b);
}

void test_zero_transition_applies_at_once() {
  Compositor comp;
  LightState s;
  comp.begin(1, s, 0);
  comp.render(s, 0, nullptr, 1000);
  s.color = {0, 255, 0};
  s.brightness = 255;
  comp.render(s, 0, nullptr, 1001);
  TEST_ASSERT_EQUAL_UINT16(65535, comp.frame()[0].g);
  TEST_ASSERT_EQUAL_UINT16(65535, comp.brightness());
}

void test_brightness_ramp_and_off() {
  Compositor comp;
  LightState s;
  comp.begin(1, s, 0);
  comp.render(s, 400, nullptr, 1000);
  s.on = false;
  comp.render(s, 1000, nullptr, 2000);
  comp.render(s, 1000, nullptr, 2500);
  TEST_ASSERT_UINT16_WITHIN(100, s.brightness * 257 / 2, comp.brightness());
  comp.render(s, 1000, nullptr, 3000);
  TEST_ASSERT_EQUAL_UINT16(0, comp.brightness());
}

void test_realtime_crossfades_in_and_out() {
  Compositor comp;
  LightState s;
  s.color = {255, 0, 0};
  comp.begin(1, s, 0);
  comp.render(s, 400, nullptr, 1000);
  const uint8_t green[3] = {0, 255, 0};
  comp.render(s, 400, green, 2000);
  TEST_ASSERT_EQUAL_UINT16(65535, comp.frame()[0].r);
  comp.render(s, 400, green, 2150);
  TEST_ASSERT_EQUAL_UINT16(65535, comp.frame()[0].g);
  comp.render(s, 400, nullptr, 3000);
  TEST_ASSERT_EQUAL_UINT16(65535, comp.frame()[0].g);
  comp.render(s, 400, nullptr, 3400);
  TEST_ASSERT_EQUAL_UINT16(65535, comp.frame()[0].r);
}

// Effects

void test_effects_are_deterministic_and_stay_in_bounds() {
  for (uint8_t e = 0; e < kEffectCount; e++) {
    for (uint16_t n : {1, 43, 480}) {
      LightState s;
      s.mode = Mode::Effect;
      s.effect = e;
      s.color = {255, 0, 0};
      s.color2 = {0, 0, 255};
      std::vector<Rgb16> a(n + 1, Rgb16{1, 2, 3}), b(n + 1, Rgb16{1, 2, 3});
      renderEffect(s, 12345, a.data(), n);
      renderEffect(s, 12345, b.data(), n);
      for (uint16_t i = 0; i < n; i++) {
        TEST_ASSERT_EQUAL_UINT16(a[i].r, b[i].r);
        TEST_ASSERT_EQUAL_UINT16(a[i].g, b[i].g);
        TEST_ASSERT_EQUAL_UINT16(a[i].b, b[i].b);
      }
      TEST_ASSERT_EQUAL_UINT16_MESSAGE(1, a[n].r, kEffects[e].id);  // nothing written past n
      TEST_ASSERT_EQUAL_UINT16_MESSAGE(3, a[n].b, kEffects[e].id);
    }
    TEST_ASSERT_EQUAL_MESSAGE(e, findEffect(kEffects[e].id), kEffects[e].id);
  }
  TEST_ASSERT_EQUAL(-1, findEffect("fire"));
}

void test_breathe_range() {
  LightState s;
  s.effect = findEffect("breathe");
  s.color = {255, 255, 255};
  Rgb16 out;
  renderEffect(s, 0, &out, 1);
  TEST_ASSERT_EQUAL_UINT16(65535, out.r);
  renderEffect(s, 32768, &out, 1);
  TEST_ASSERT_UINT16_WITHIN(20, 9830, out.r);  // 15 %
}

void test_gradient_endpoints() {
  LightState s;
  s.effect = findEffect("gradient");
  s.color = {255, 0, 0};
  s.color2 = {0, 0, 255};
  Rgb16 out[43];
  renderEffect(s, 0, out, 43);
  TEST_ASSERT_EQUAL_UINT16(65535, out[0].r);
  TEST_ASSERT_EQUAL_UINT16(0, out[0].b);
  TEST_ASSERT_EQUAL_UINT16(0, out[42].r);
  TEST_ASSERT_EQUAL_UINT16(65535, out[42].b);
}

void test_scan_band_starts_at_the_first_led() {
  LightState s;
  s.effect = findEffect("scan");
  s.color = {255, 255, 255};
  s.color2 = {0, 0, 0};
  Rgb16 out[43];
  renderEffect(s, 0, out, 43);
  TEST_ASSERT_EQUAL_UINT16(65535, out[0].r);
  TEST_ASSERT_EQUAL_UINT16(0, out[42].r);
}

void test_effect_periods_follow_speed() {
  const int breathe = findEffect("breathe");
  TEST_ASSERT_EQUAL_UINT32(12000, effectPeriodMs(breathe, 0));
  TEST_ASSERT_UINT32_WITHIN(1, 2000, effectPeriodMs(breathe, 255));
  TEST_ASSERT_TRUE(effectPeriodMs(breathe, 200) < effectPeriodMs(breathe, 100));
  TEST_ASSERT_EQUAL_UINT32(0, effectPeriodMs(findEffect("gradient"), 128));
}

void test_linear_round_trip() {
  TEST_ASSERT_EQUAL_UINT16(0, linearToSrgb16(srgbToLinear(0)));
  for (int c = 2; c < 256; c++) TEST_ASSERT_EQUAL_UINT16(c * 257, linearToSrgb16(srgbToLinear(c)));
}

// Overlays

void test_identify_overlay_flashes_three_times() {
  Rgb16 out[2];
  TEST_ASSERT_TRUE(renderOverlay(Overlay::Identify, 0, 0, out, 2));
  TEST_ASSERT_EQUAL_UINT16(40 * 257, out[1].g);
  TEST_ASSERT_TRUE(renderOverlay(Overlay::Identify, 300, 0, out, 2));
  TEST_ASSERT_EQUAL_UINT16(0, out[1].g);
  TEST_ASSERT_FALSE(renderOverlay(Overlay::Identify, 1500, 0, out, 2));
  TEST_ASSERT_FALSE(renderOverlay(Overlay::None, 0, 0, out, 2));
}

void test_progress_overlay() {
  Rgb16 out[10];
  TEST_ASSERT_TRUE(renderOverlay(Overlay::Progress, 0, 500, out, 10));
  TEST_ASSERT_EQUAL_UINT16(40 * 257, out[4].b);
  TEST_ASSERT_EQUAL_UINT16(0, out[5].b);
}

int main() {
  UNITY_BEGIN();
  RUN_TEST(test_effects_match_fixture);
  RUN_TEST(test_default_state_matches_fixture);
  RUN_TEST(test_default_config_matches_fixture);
  RUN_TEST(test_state_patches);
  RUN_TEST(test_config_patches);
  RUN_TEST(test_ddp_packets);
  RUN_TEST(test_unchanged_values_do_not_count_as_change);
  RUN_TEST(test_realtime_times_out);
  RUN_TEST(test_realtime_ignored_while_off);
  RUN_TEST(test_realtime_end_blocks_sender_until_it_pauses);
  RUN_TEST(test_realtime_end_does_not_block_other_senders);
  RUN_TEST(test_realtime_end_without_stream_blocks_nothing);
  RUN_TEST(test_realtime_most_recent_sender_wins);
  RUN_TEST(test_pipeline_zero_brightness_is_black);
  RUN_TEST(test_pipeline_full_white_is_full_output);
  RUN_TEST(test_pipeline_gamma_is_monotonic);
  RUN_TEST(test_pipeline_white_balance);
  RUN_TEST(test_pipeline_current_limit);
  RUN_TEST(test_pipeline_dither_averages_to_the_16_bit_value);
  RUN_TEST(test_pipeline_black_channel_stays_black_with_dither);
  RUN_TEST(test_pipeline_reverse_and_color_order);
  RUN_TEST(test_boot_fades_in);
  RUN_TEST(test_crossfade_endpoints_are_exact);
  RUN_TEST(test_zero_transition_applies_at_once);
  RUN_TEST(test_brightness_ramp_and_off);
  RUN_TEST(test_realtime_crossfades_in_and_out);
  RUN_TEST(test_effects_are_deterministic_and_stay_in_bounds);
  RUN_TEST(test_breathe_range);
  RUN_TEST(test_gradient_endpoints);
  RUN_TEST(test_scan_band_starts_at_the_first_led);
  RUN_TEST(test_effect_periods_follow_speed);
  RUN_TEST(test_linear_round_trip);
  RUN_TEST(test_identify_overlay_flashes_three_times);
  RUN_TEST(test_progress_overlay);
  return UNITY_END();
}
