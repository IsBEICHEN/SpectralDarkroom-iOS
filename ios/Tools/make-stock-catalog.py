#!/usr/bin/env python3
"""Build the iOS stock picker from the profiles actually bundled in the app."""
import json
import pathlib
import sys

resources = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
translations = {
    "fujifilm_c200": "富士 C200",
    "fujifilm_pro_400h": "富士专业 400H",
    "fujifilm_provia_100f": "富士普罗维亚 100F",
    "fujifilm_velvia_100": "富士维尔维亚 100",
    "fujifilm_xtra_400": "富士 Superia X-TRA 400",
    "fujifilm_crystal_archive_typeii": "富士晶彩 II",
    "fujifilm_neopan_acros_100_ii": "富士 Neopan Acros 100 II",
    "kodak_2383": "柯达 Vision 2383",
    "kodak_2393": "柯达 Vision 2393",
    "kodak_ektachrome_100": "柯达 Ektachrome 100",
    "kodak_ektacolor_edge": "柯达 Ektacolor Edge",
    "kodak_ektar_100": "柯达 Ektar 100",
    "kodak_endura_premier": "柯达 Endura Premier",
    "kodak_gold_200": "柯达金 200",
    "kodak_kodachrome_64": "柯达 Kodachrome 64",
    "kodak_portra_160": "柯达人像 160",
    "kodak_portra_400": "柯达人像 400",
    "kodak_portra_800": "柯达人像 800",
    "kodak_portra_800_push1": "柯达人像 800 增感 +1",
    "kodak_portra_800_push2": "柯达人像 800 增感 +2",
    "kodak_portra_endura": "柯达人像 Endura",
    "kodak_supra_endura": "柯达 Supra Endura",
    "kodak_ultra_endura": "柯达 Ultra Endura",
    "kodak_ultramax_400": "柯达 Ultramax 400",
    "kodak_verita_200d": "柯达 Verita 200D",
    "kodak_vision3_200t": "柯达 Vision3 200T",
    "kodak_vision3_250d": "柯达 Vision3 250D",
    "kodak_vision3_500t": "柯达 Vision3 500T",
    "kodak_vision3_50d": "柯达 Vision3 50D",
    "cinestill_800t": "CineStill 800T",
    "ilford_hp5_plus_400": "伊尔福 HP5 Plus 400",
    "ilford_multigrade_iv_rc": "伊尔福 Multigrade IV RC",
    "kodak_tmax_100": "柯达 T-Max 100",
    "kodak_tri_x_400": "柯达 Tri-X 400",
}
catalog = {"films": [], "papers": []}
filters = json.loads((resources / "neutral_print_filters.json").read_text())
for profile in sorted((resources / "profiles").glob("*.json")):
    data = json.loads(profile.read_text())
    info = data["info"]
    identifier = profile.stem
    if data.get("derived_from"):
        parent = json.loads((resources / "profiles" / (data["derived_from"] + ".json")).read_text())
        info = {**parent["info"], **info}
    stage = info["stage"]
    if stage not in ("filming", "printing"):
        raise ValueError(f"Unknown stage for {identifier}: {stage}")
    if identifier not in translations:
        raise ValueError(f"Missing Chinese name for {identifier}")
    bw = info.get("channel_model") == "bw"
    positive = info.get("type") == "positive"
    if stage == "filming":
        category = ("黑白胶片" if bw else "反转片" if positive else
                    "电影负片" if info.get("use") == "cine" or identifier == "cinestill_800t"
                    else "彩色负片")
    else:
        category = "黑白相纸" if bw else "电影拷贝" if info.get("use") == "cine" else "彩色相纸"
    filter_id = data.get("derived_from") or identifier
    calibrated = [
        paper for paper, illuminants in filters.items()
        if filter_id in illuminants.get("TH-KG3", {})
    ] if stage == "filming" else []
    item = {"id": identifier, "label": translations[identifier],
            "originalName": info["name"], "targetPrint": info.get("target_print") or "",
            "category": category, "positive": positive,
            "strongHalation": info.get("antihalation") == "no",
            "calibratedPapers": calibrated}
    catalog["films" if stage == "filming" else "papers"].append(item)
if not catalog["films"] or not catalog["papers"]:
    raise ValueError("Empty film or paper catalog")
featured_films = ["kodak_portra_400", "kodak_gold_200", "fujifilm_c200"]
featured_papers = ["kodak_portra_endura", "fujifilm_crystal_archive_typeii"]
for key, featured in (("films", featured_films), ("papers", featured_papers)):
    catalog[key].sort(key=lambda item: (
        featured.index(item["id"]) if item["id"] in featured else len(featured),
        item["id"]
    ))
output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
print(f"{len(catalog['films'])} films, {len(catalog['papers'])} print stocks")
