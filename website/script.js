const header = document.querySelector(".site-header");

function updateHeaderState() {
  header?.classList.toggle("is-scrolled", window.scrollY > 8);
}

window.addEventListener("scroll", updateHeaderState, { passive: true });
updateHeaderState();

function initThoughtMap(canvas, options) {
  if (!canvas) return;

  const context = canvas.getContext("2d");
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const nodes = [];
  const pointer = { x: 0, y: 0, active: false };
  let width = 0;
  let height = 0;
  let frame = 0;
  let animationId = 0;

  const nodeCount = options.count;

  function resize() {
    const rect = canvas.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    width = Math.max(1, rect.width);
    height = Math.max(1, rect.height);
    canvas.width = Math.floor(width * ratio);
    canvas.height = Math.floor(height * ratio);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);

    nodes.length = 0;
    for (let index = 0; index < nodeCount; index += 1) {
      const angle = (Math.PI * 2 * index) / nodeCount;
      const ring = index % 3;
      const radiusX = width * (0.22 + ring * 0.09);
      const radiusY = height * (0.18 + ring * 0.07);
      nodes.push({
        x: width * 0.5 + Math.cos(angle) * radiusX + seeded(index, 23) * 80 - 40,
        y: height * 0.5 + Math.sin(angle) * radiusY + seeded(index, 47) * 70 - 35,
        baseX: width * 0.5 + Math.cos(angle) * radiusX,
        baseY: height * 0.5 + Math.sin(angle) * radiusY,
        vx: seeded(index, 11) * 0.34 - 0.17,
        vy: seeded(index, 19) * 0.34 - 0.17,
        r: 3.5 + seeded(index, 31) * 6,
        label: options.labels[index % options.labels.length],
      });
    }

    draw();
  }

  function seeded(index, salt) {
    const value = Math.sin(index * 999 + salt * 131) * 10000;
    return value - Math.floor(value);
  }

  function step() {
    frame += 1;
    for (const node of nodes) {
      if (!reducedMotion) {
        node.x += node.vx;
        node.y += node.vy;
      }

      const homePull = 0.0025;
      node.vx += (node.baseX - node.x) * homePull;
      node.vy += (node.baseY - node.y) * homePull;

      if (pointer.active) {
        const dx = node.x - pointer.x;
        const dy = node.y - pointer.y;
        const distance = Math.max(1, Math.hypot(dx, dy));
        if (distance < 180) {
          const push = (180 - distance) * 0.0009;
          node.vx += (dx / distance) * push;
          node.vy += (dy / distance) * push;
        }
      }

      node.vx *= 0.992;
      node.vy *= 0.992;

      if (node.x < 24 || node.x > width - 24) node.vx *= -1;
      if (node.y < 24 || node.y > height - 24) node.vy *= -1;
    }
    draw();

    if (!reducedMotion) {
      animationId = window.requestAnimationFrame(step);
    }
  }

  function draw() {
    context.clearRect(0, 0, width, height);

    if (options.fill) {
      context.fillStyle = options.fill;
      context.fillRect(0, 0, width, height);
    }

    for (let i = 0; i < nodes.length; i += 1) {
      for (let j = i + 1; j < nodes.length; j += 1) {
        const a = nodes[i];
        const b = nodes[j];
        const distance = Math.hypot(a.x - b.x, a.y - b.y);
        if (distance > options.linkDistance) continue;

        const alpha = (1 - distance / options.linkDistance) * options.lineAlpha;
        context.strokeStyle = options.line.replace("{alpha}", alpha.toFixed(3));
        context.lineWidth = options.lineWidth;
        context.beginPath();
        context.moveTo(a.x, a.y);
        context.lineTo(b.x, b.y);
        context.stroke();
      }
    }

    for (const node of nodes) {
      const pulse = reducedMotion ? 0 : Math.sin(frame * 0.025 + node.r) * 0.9;
      context.beginPath();
      context.arc(node.x, node.y, node.r + pulse, 0, Math.PI * 2);
      context.fillStyle = options.node;
      context.fill();

      context.beginPath();
      context.arc(node.x, node.y, node.r + 4 + pulse, 0, Math.PI * 2);
      context.strokeStyle = options.ring;
      context.lineWidth = 1;
      context.stroke();
    }

    if (options.showLabels) {
      context.font = "700 13px 'Nunito Nous', system-ui, sans-serif";
      context.textBaseline = "middle";
      context.fillStyle = options.label;
      for (const node of nodes.slice(0, 8)) {
        context.fillText(node.label, node.x + node.r + 10, node.y);
      }
    }
  }

  canvas.addEventListener("pointermove", (event) => {
    const rect = canvas.getBoundingClientRect();
    pointer.x = event.clientX - rect.left;
    pointer.y = event.clientY - rect.top;
    pointer.active = true;
  });

  canvas.addEventListener("pointerleave", () => {
    pointer.active = false;
  });

  window.addEventListener("resize", resize, { passive: true });
  resize();
  if (reducedMotion) {
    draw();
  } else {
    animationId = window.requestAnimationFrame(step);
  }

  return () => {
    window.cancelAnimationFrame(animationId);
    window.removeEventListener("resize", resize);
  };
}

initThoughtMap(document.getElementById("heroGalaxy"), {
  count: 26,
  labels: ["idea", "note", "chat", "project", "memory", "decision"],
  linkDistance: 210,
  lineAlpha: 0.28,
  lineWidth: 1,
  line: "rgba(20, 20, 19, {alpha})",
  node: "rgba(243, 131, 53, 0.86)",
  ring: "rgba(20, 20, 19, 0.18)",
  label: "rgba(20, 20, 19, 0.48)",
  showLabels: true,
});

initThoughtMap(document.getElementById("featureGalaxy"), {
  count: 34,
  labels: ["idea", "note", "question", "project", "memory", "decision"],
  linkDistance: 170,
  lineAlpha: 0.46,
  lineWidth: 1.1,
  line: "rgba(253, 251, 247, {alpha})",
  node: "rgba(243, 131, 53, 0.94)",
  ring: "rgba(243, 131, 53, 0.24)",
  label: "rgba(253, 251, 247, 0.74)",
  fill: "#20203a",
  showLabels: true,
});
