/* =============================================================
   Holdable — Prism Studio
   Vanilla JS controller. No build step, no dependencies.
   ============================================================= */

(function(){
  "use strict";

  /* ---------- 3D octahedron — interactive on the viewer ---------- */
  const VERTS = [[0,-1,0],[1,0,0],[0,0,1],[-1,0,0],[0,0,-1],[0,1,0]];
  const FACES = [[0,1,2],[0,2,3],[0,3,4],[0,4,1],[5,2,1],[5,3,2],[5,4,3],[5,1,4]];
  const SVGNS = "http://www.w3.org/2000/svg";

  function makeSpinner(svg, opts){
    opts = opts || {};
    const baseScale  = opts.scale  || 78;
    const speed  = opts.speed  || 0.00055;
    const tilt   = opts.tilt   != null ? opts.tilt : 0.4;
    const stroke = opts.stroke || null;
    const strokeW = opts.strokeW || 0;
    const interactive = !!opts.interactive;

    // gradient fill
    const defs = document.createElementNS(SVGNS,"defs");
    const lg = document.createElementNS(SVGNS,"linearGradient");
    const gid = opts.gradientId || ("g-" + Math.random().toString(36).slice(2,8));
    lg.setAttribute("id", gid);
    lg.setAttribute("x1","0%");lg.setAttribute("y1","0%");
    lg.setAttribute("x2","100%");lg.setAttribute("y2","100%");
    [["0%","#FF5CB4"],["50%","#8B6CFF"],["100%","#4FE0E5"]].forEach(([o,c])=>{
      const st = document.createElementNS(SVGNS,"stop");
      st.setAttribute("offset", o);
      st.setAttribute("stop-color", c);
      lg.appendChild(st);
    });
    defs.appendChild(lg);
    svg.appendChild(defs);

    const polys = FACES.map(()=>{
      const p = document.createElementNS(SVGNS,"polygon");
      p.setAttribute("fill", `url(#${gid})`);
      if(stroke){ p.setAttribute("stroke", stroke); p.setAttribute("stroke-width", strokeW); p.setAttribute("stroke-linejoin","round"); }
      svg.appendChild(p);
      return p;
    });

    let rotY = 0, rotX = tilt * 0.5;
    let velY = 0, velX = 0;
    let userScale = 1;
    let dragging = false, lastX = 0, lastY = 0;
    let idleSince = performance.now();
    let pinchDist = 0;

    if(interactive){
      svg.style.touchAction = "none";
      svg.style.cursor = "grab";
      const active = new Map();

      svg.addEventListener("pointerdown", (e)=>{
        e.preventDefault();
        svg.setPointerCapture(e.pointerId);
        active.set(e.pointerId, {x:e.clientX, y:e.clientY});
        if(active.size === 1){
          dragging = true; lastX = e.clientX; lastY = e.clientY;
          velY = velX = 0;
          svg.style.cursor = "grabbing";
        } else if(active.size === 2){
          const pts = [...active.values()];
          pinchDist = Math.hypot(pts[0].x-pts[1].x, pts[0].y-pts[1].y);
          dragging = false;
        }
        idleSince = performance.now();
      });

      svg.addEventListener("pointermove", (e)=>{
        if(!active.has(e.pointerId)) return;
        active.set(e.pointerId, {x:e.clientX, y:e.clientY});
        if(active.size === 1 && dragging){
          const dx = e.clientX - lastX, dy = e.clientY - lastY;
          rotY += dx * 0.012;
          rotX += dy * 0.012;
          rotX = Math.max(-1.3, Math.min(1.3, rotX));
          velY = dx * 0.012; velX = dy * 0.012;
          lastX = e.clientX; lastY = e.clientY;
          idleSince = performance.now();
        } else if(active.size === 2){
          const pts = [...active.values()];
          const d = Math.hypot(pts[0].x-pts[1].x, pts[0].y-pts[1].y);
          if(pinchDist > 0){
            userScale = Math.max(0.5, Math.min(1.8, userScale * (d / pinchDist)));
          }
          pinchDist = d;
          idleSince = performance.now();
        }
      });

      const endPointer = (e)=>{
        active.delete(e.pointerId);
        if(active.size < 2) pinchDist = 0;
        if(active.size === 0){ dragging = false; svg.style.cursor = "grab"; }
      };
      svg.addEventListener("pointerup", endPointer);
      svg.addEventListener("pointercancel", endPointer);
      svg.addEventListener("pointerleave", endPointer);

      svg.addEventListener("wheel", (e)=>{
        e.preventDefault();
        userScale = Math.max(0.5, Math.min(1.8, userScale * Math.exp(-e.deltaY * 0.0015)));
        idleSince = performance.now();
      }, {passive:false});
    }

    let lastT = performance.now();
    function frame(t){
      const dt = Math.min(t - lastT, 50); lastT = t;
      const idleMs = t - idleSince;

      if(interactive){
        if(!dragging){
          rotY += velY; rotX += velX;
          velY *= 0.93; velX *= 0.93;
          if(Math.abs(velY) < 0.0002) velY = 0;
          if(Math.abs(velX) < 0.0002) velX = 0;
          if(idleMs > 1400 && velY === 0 && velX === 0){
            rotY += dt * 0.0005;
          }
          rotX += (tilt * 0.4 - rotX) * 0.005;
        }
      } else {
        rotY = t * speed;
        rotX = Math.sin(t * speed * 0.7) * tilt;
      }

      const s  = baseScale * userScale;
      const cy = Math.cos(rotY), sy = Math.sin(rotY);
      const cx = Math.cos(rotX), sx = Math.sin(rotX);

      const pj = VERTS.map(v=>{
        const x = v[0]*cy + v[2]*sy;
        const z = -v[0]*sy + v[2]*cy;
        const y = v[1]*cx - z*sx;
        const z2 = v[1]*sx + z*cx;
        return { x: x*s, y: y*s, z: z2 };
      });

      const order = FACES.map((f,i)=>({ i, z:(pj[f[0]].z+pj[f[1]].z+pj[f[2]].z)/3 }))
        .sort((a,b)=>a.z-b.z);

      order.forEach(o=>{
        const p = polys[o.i];
        const f = FACES[o.i];
        p.setAttribute("points", f.map(vi=>`${pj[vi].x.toFixed(1)},${pj[vi].y.toFixed(1)}`).join(" "));
        const shade = (o.z + 1)/2;
        p.setAttribute("opacity", (0.45 + shade*0.55).toFixed(3));
        svg.appendChild(p);
      });
      requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  /* ---------- Model catalogue ---------- */
  const MODELS = {
    beetle: { name:"Beetle bust",       ref:"REF 001", ext:"OBJ",   size:"2.4 MB",  verts:"6,204",  tris:"12,408" },
    hex:    { name:"Hex pendant",       ref:"REF 002", ext:"STL",   size:"812 KB",  verts:"1,058",  tris:"2,104"  },
    cube:   { name:"Cube study 04",     ref:"REF 003", ext:"BLEND", size:"9.1 MB",  verts:"22,108", tris:"44,200" },
    lampy:  { name:"Lamp shade rev.B",  ref:"REF 004", ext:"OBJ",   size:"3.7 MB",  verts:"3,415",  tris:"6,820"  }
  };

  function applyModel(modelId){
    const m = MODELS[modelId]; if(!m) return;
    const phone = document.getElementById("phone");
    // viewer
    setText(phone, '[data-screen="viewer"] [data-field="name"]', m.name);
    setText(phone, '[data-screen="viewer"] [data-field="meta"]', `${m.ref} · ${m.ext} · ${m.tris} TRIS`);
    // action sheet
    setText(phone, '[data-screen="action-sheet"] [data-field="name"]', m.name);
    setText(phone, '[data-screen="action-sheet"] [data-field="meta"]', `${m.ref} · ${m.ext} · ${m.tris} TRIS`);
    // info
    setText(phone, '[data-screen="info"] [data-field="ref"]', m.ref);
    setText(phone, '[data-screen="info"] [data-field="ext"]', m.ext);
    setText(phone, '[data-screen="info"] [data-field="size"]', m.size);
    setText(phone, '[data-screen="info"] [data-field="verts"]', m.verts);
    setText(phone, '[data-screen="info"] [data-field="tris"]', m.tris);
  }
  function setText(root, sel, txt){ const el = root.querySelector(sel); if(el) el.textContent = txt; }

  /* ---------- Routing (with overlay support for sheets) ---------- */
  const phone = document.getElementById("phone");
  const screen = phone.querySelector(".screen");
  let underlay = "ob1"; // last non-overlay screen — sheets render on top

  function show(target){
    const targetEl = phone.querySelector(`.scr-page[data-screen="${target}"]`);
    if(!targetEl) return;
    const isOverlay = targetEl.dataset.overlay === "true";

    if(isOverlay){
      // Keep the underlay screen visible behind the sheet
      phone.querySelectorAll(".scr-page").forEach(el=>{
        const active = (el.dataset.screen === underlay) || (el === targetEl);
        el.classList.toggle("active", active);
      });
    } else {
      // hide everything, show only target
      phone.querySelectorAll(".scr-page").forEach(el=>{
        el.classList.toggle("active", el === targetEl);
      });
      underlay = target;
    }
    // Sync screen index
    document.querySelectorAll(".index .row").forEach(r=>{
      r.classList.toggle("active", r.dataset.jump === target);
    });
  }

  /* ---------- Theme ---------- */
  function setTheme(t){
    screen.setAttribute("data-theme", t);
    // sync segmented buttons in profile
    phone.querySelectorAll('[data-action="theme-seg"] button').forEach(b=>{
      b.classList.toggle("on", b.dataset.themeSet === t);
    });
  }
  function toggleTheme(){
    const cur = screen.getAttribute("data-theme") || "dark";
    setTheme(cur === "dark" ? "light" : "dark");
  }

  /* ---------- Wire interactions ---------- */
  phone.addEventListener("click", (e)=>{
    // theme toggle
    const themeBtn = e.target.closest('[data-action="theme"]');
    if(themeBtn){ toggleTheme(); return; }
    const themeSeg = e.target.closest('[data-theme-set]');
    if(themeSeg){ setTheme(themeSeg.dataset.themeSet); return; }

    // preset selection (render screen)
    const preset = e.target.closest("[data-preset]");
    if(preset){
      phone.querySelectorAll("[data-preset]").forEach(p=>p.classList.toggle("on", p === preset));
      return;
    }

    // nav
    const go = e.target.closest("[data-go]");
    if(!go) return;
    const target = go.dataset.go;
    if(go.dataset.model) applyModel(go.dataset.model);
    show(target);
  });

  // Screen index
  document.querySelectorAll(".index .row[data-jump]").forEach(row=>{
    row.addEventListener("click", ()=>{
      const t = row.dataset.jump;
      // If target is an overlay sheet but no real underlay set, point to logical source
      const target = phone.querySelector(`.scr-page[data-screen="${t}"]`);
      if(target && target.dataset.overlay === "true"){
        // pick a sensible underlay for direct jumps
        underlay = (t === "import-sheet") ? "lib" : "viewer";
        if(t === "action-sheet") applyModel("beetle");
      }
      show(t);
    });
  });

  /* ---------- Init spinners ---------- */
  document.querySelectorAll("[data-spinner]").forEach(svg=>{
    const id = svg.dataset.spinner;
    const isViewer = id === "viewer";
    makeSpinner(svg, {
      scale: isViewer ? 84 : 72,
      speed: 0.0005,
      stroke: "rgba(255,255,255,0.18)",
      strokeW: 0.6,
      tilt: 0.4,
      interactive: isViewer,
      gradientId: "grad-" + id
    });
  });

  /* ---------- Init state ---------- */
  setTheme("dark");
  document.querySelectorAll(".index .row").forEach(r=>{
    r.classList.toggle("active", r.dataset.jump === "ob1");
  });

  /* ---------- Download link (informational) ---------- */
  const dl = document.getElementById("download-link");
  if(dl){
    dl.addEventListener("click", (e)=>{
      e.preventDefault();
      dl.textContent = "Use the download card in chat ↑";
      setTimeout(()=>{ dl.textContent = "Download .zip →"; }, 2200);
    });
  }

})();
