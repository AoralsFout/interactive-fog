"""Measure the fine-grid Poisson equation from Godot GPU readbacks and plot MAC flow."""
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.sparse import coo_matrix
from scipy.sparse.linalg import spsolve


ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / ".godot/pressure-comparison"
OUT = ROOT / "artifacts/pressure-solver"
MODES = ("jacobi", "multigrid", "multigrid-3")
CASES = ("cold", "matched", "wake", "moved", "sealed")


def read(folder, case, key, n, channels=4, dtype="<f2"):
    data = np.fromfile(folder / f"{case}-{key}.bin", dtype)
    return data.reshape(n, n, channels).astype(np.float64)


def norm(field):
    return float(np.linalg.norm(field))


def metrics(folder, case, n):
    geom = read(folder, case, "geom", n, dtype="<f4")
    bits = geom[:, :, 0].astype(int)
    fluid = geom[:, :, 3] < 9999
    rhs = read(folder, case, "before", n)[:, :, 0]
    pressure = read(folder, case, "p", n, 1, "<f4")[:, :, 0]
    vel = read(folder, case, "mac", n)[:, :, :2]
    pred = read(folder, case, "predict", n)[:, :, :2]
    post = read(folder, case, "after", n)[:, :, 0]
    sdf = read(folder, case, "mask", n*2)[:, :, 0].reshape(n, 2, n, 2).mean(axis=(1, 3))
    near = fluid & (sdf <= 0.5)
    # A = -L. The stored stencil includes external zero-pressure faces in its
    # diagonal, but no neighbor entries on solid or external faces.
    ids = np.arange(n*n).reshape(n, n)
    rows, cols = [ids.ravel()], [ids.ravel()]
    diag = 1.0/geom[:, :, 3]
    coeffs = [np.where(fluid, diag, 1).ravel()]
    for i, offset in enumerate((-1, 1, -n, n)):
        connected = bits & (1 << i) != 0
        rows.append(ids[connected])
        cols.append(ids[connected] + offset)
        coeffs.append(-(geom[:, :, 1+i//2]*diag)[connected])
    matrix = coo_matrix((np.concatenate(coeffs), (np.concatenate(rows), np.concatenate(cols))),
                        shape=(n*n, n*n)).tocsr()
    residual = (matrix @ pressure.ravel()).reshape(n, n) + rhs
    ref_p = spsolve(matrix, -rhs.ravel()).reshape(n, n)
    ref_residual = (matrix @ ref_p.ravel()).reshape(n, n) + rhs
    ref_v = pred.copy()
    blocked_max = 0.0
    for axis, (flag, length) in enumerate(((2, 24.0), (8, 20.0))):
        other = np.roll(ref_p, -1, axis=1-axis)
        open_face = (bits & flag) != 0
        edge = np.s_[:, -1] if axis == 0 else np.s_[-1, :]
        open_face[edge] = fluid[edge]
        other[edge] = 0
        ref_v[:, :, axis] = np.where(open_face, pred[:, :, axis]-(other-ref_p)*n/length, 0)
        blocked_max = max(blocked_max, float(np.abs(vel[:, :, axis][~open_face]).max(initial=0)))
    ref_v *= np.minimum(1, 5.0/np.maximum(np.linalg.norm(ref_v, axis=2), 1e-20))[:, :, None]
    result = {
        "relative_l2_residual": norm(residual[fluid])/norm(rhs[fluid]),
        "reference_relative_l2": norm(ref_residual[fluid])/norm(rhs[fluid]),
        "near_residual_rms": norm(residual[near])/np.sqrt(near.sum()),
        "near_velocity_rmse_mps": norm((ref_v-vel)[near])/np.sqrt(near.sum()),
        "blocked_face_max_mps": blocked_max,
        "post_divergence_rms": norm(post[fluid])/np.sqrt(fluid.sum()),
    }
    if case != "sealed":
        # Flux per unit height across the central 0.6 m opening at x=2.
        i = round((2/24+0.5)*n)-1
        z = ((np.arange(n)+0.5)/n-0.5)*20
        slot = (abs(z) < 0.30) & fluid[:, i]
        result["gap_flux_m2ps"] = float(vel[slot,i,0].sum()*20/n)
        result["reference_gap_flux_m2ps"] = float(ref_v[slot,i,0].sum()*20/n)
    if case == "sealed":
        right = (np.arange(n)+0.5)*24/n-12 > 0.5
        result["unforced_side_max_mps"] = float(np.abs(vel[:, right]).max())
        result["unforced_side_max_pressure"] = float(np.abs(pressure[:, right]).max())
    assert all(np.isfinite(v) for v in result.values()) and result["reference_relative_l2"] < 1e-8
    assert blocked_max == 0
    return result, (vel, sdf), (ref_v, sdf)


def draw_flow(rows):
    # World-space arrows use the velocity interpolated to cell centers. Each
    # panel has the same camera, meters-per-pixel and velocity/color scales.
    w, h = 450, 310
    image = Image.new("RGB", (3*w, 2*(h+38)+40), "#152029")
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 16)
    except OSError:
        try:
            font = ImageFont.truetype("segoeui.ttf", 16)
        except OSError:
            font = ImageFont.load_default()
    palette = np.array([[22, 38, 51], [32, 107, 130], [62, 175, 162], [239, 189, 96]])
    for row, cases in enumerate(rows):
        for col, (vel, sdf) in enumerate(cases):
            n = len(sdf)
            v = vel.copy()
            v[:, :, 0] = (vel[:, :, 0]+np.roll(vel[:, :, 0], 1, axis=1))*0.5
            v[:, :, 1] = (vel[:, :, 1]+np.roll(vel[:, :, 1], 1, axis=0))*0.5
            ix = np.floor(((np.arange(w)+0.5-w/2)/45/24+0.5)*n).astype(int)
            iz = np.floor(((np.arange(h)+0.5-h/2)/45/20+0.5)*n).astype(int)
            region = np.ix_(iz, ix)
            speed = np.linalg.norm(v[region], axis=2)
            rgb = np.stack([np.interp(speed, [0,0.8,1.6,2.4], channel) for channel in palette.T], axis=2)
            rgb[sdf[region] <= 0] = [12, 15, 21]
            x0, y0 = w*col, (h+38)*row+38
            image.paste(Image.fromarray(rgb.astype("uint8")), (x0, y0))
            title = ("Cold" if row == 0 else "Shared warm start") + "  |  " + ("Jacobi 64", "Multigrid 2V", "Direct reference")[col]
            draw.text((x0+10, y0-28), title, font=font, fill="white")
            for y in range(10, h, 19):
                for x in range(10, w, 19):
                    if sdf[iz[y], ix[x]] <= 0:
                        continue
                    dx, dy = v[iz[y], ix[x]]*8
                    length = np.hypot(dx, dy)
                    if length < 0.8:
                        continue
                    px, py = x0+x+dx, y0+y+dy
                    draw.line((x0+x,y0+y,px,py), fill="#deeee8")
                    for side in [-1, 1]:
                        draw.line((px,py,px-(dx+side*dy*0.6)*3/length,
                                   py-(dy-side*dx*0.6)*3/length), fill="#deeee8")
    draw.text((10,image.height-28), "XZ top view   |   arrows: 8 px per m/s   |   speed: dark blue 0, teal 1.6, gold >=2.4 m/s   |   black: solid", font=font, fill="white")
    image.save(OUT / "obstacle-flow.png")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}
    panels = {"cold": [], "matched": []}
    for n in (256, 65):
        base = RAW / str(n)
        cases = {}
        for case in CASES:
            cases[case] = {}
            for mode in MODES:
                stats, flow, reference = metrics(base/mode, case, n)
                cases[case][mode] = stats
                if n == 256 and case in panels and mode != "multigrid-3":
                    panels[case].append(flow)
                    if mode == "multigrid":
                        panels[case].append(reference)
        for file in ("warm_start-p", "matched-geom", "matched-predict", "matched-before", "cold-before"):
            baseline = (base/MODES[0]/(file+".bin")).read_bytes()
            for mode in MODES[1:]:
                assert (base/mode/(file+".bin")).read_bytes() == baseline, file
        for mode in MODES:
            assert cases["sealed"][mode]["unforced_side_max_mps"] == 0
            assert cases["sealed"][mode]["unforced_side_max_pressure"] == 0
        report[str(n)] = cases
    (OUT/"accuracy.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    draw_flow([panels["cold"], panels["matched"]])


if __name__ == "__main__":
    main()
