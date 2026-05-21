// web/static/progress.js — SSE listener + mise à jour live des étapes/logs.
//
// Règle modale :
//   - L'arrivée sur la page avec un workspace DÉJÀ terminé n'ouvre PAS de modal.
//     On affiche juste une bannière + la section "liens" en bas, non-bloquant.
//   - Le modal "🎉 Terminé" ne s'ouvre QUE quand la fin arrive en LIVE pendant
//     que tu regardes la page (SSE "done" reçu, pas via /state initial).
//   - Le modal a un bouton ×, un bouton "Continuer ici" et "Retour".

(() => {
  const body = document.body;
  const eventsUrl = body.dataset.eventsUrl;
  const stateUrl  = body.dataset.stateUrl;
  const stopUrl   = body.dataset.stopUrl;

  const statusLine = document.getElementById("status-line");
  const logOutput = document.getElementById("log-output");
  const logStatus = document.getElementById("log-status");
  const successModal = document.getElementById("success-modal");
  const modalLinks = document.getElementById("modal-links");
  const successBanner = document.getElementById("success-banner");
  const successSection = document.getElementById("success-section");
  const successLinks = document.getElementById("success-links");
  const stopBtn = document.getElementById("stop-btn");
  const steps = Array.from(document.querySelectorAll(".step"));

  let firstChunk = true;
  let wasRunningAtLoad = null;     // null = pas encore connu, true/false = état au chargement
  let liveCompletion = false;      // true si la fin survient pendant cette session
  let es = null;                   // EventSource handle (pour le fermer au stop)

  // ----- État initial ------------------------------------------------------
  fetch(stateUrl).then(r => r.json()).then((s) => {
    s.completed.forEach(markStepDone);
    updateActiveStep();

    wasRunningAtLoad = s.running;
    const allDone = s.completed.length === s.total;

    if (!s.running && allDone) {
      // Déjà terminé AVANT mon arrivée → bannière + section, pas de modal
      showStaticSuccess();
      stopBtn.disabled = true;
      logStatus.textContent = "terminé";
      logStatus.classList.remove("live");
      logStatus.classList.add("done");
      statusLine.textContent = "Workspace déjà déployé (état préservé entre sessions)";
    } else if (!s.running && s.completed.length === 0) {
      statusLine.textContent = "Aucun bootstrap en cours.";
      logStatus.textContent = "idle";
      stopBtn.disabled = true;
    } else if (!s.running) {
      // Interrompu en cours de route
      statusLine.textContent = "Bootstrap interrompu — voir les logs.";
      logStatus.textContent = "interrompu";
      logStatus.classList.remove("live");
      logStatus.classList.add("error");
      stopBtn.disabled = true;
    } else {
      statusLine.textContent = "Bootstrap en cours…";
    }
  });

  // ----- SSE ---------------------------------------------------------------
  es = new EventSource(eventsUrl);
  logStatus.textContent = "live";
  logStatus.classList.add("live");

  es.addEventListener("open", () => {
    logStatus.textContent = "live";
    logStatus.classList.add("live");
    logStatus.classList.remove("error");
  });

  es.addEventListener("error", () => {
    // L'EventSource se reconnecte tout seul. On reflète juste l'état.
    if (!stopBtn.disabled) {
      logStatus.textContent = "déconnecté";
      logStatus.classList.remove("live");
      logStatus.classList.add("error");
    }
  });

  es.addEventListener("message", (e) => {
    const msg = JSON.parse(e.data);
    if (msg.type === "log") {
      appendLog(msg.line);
    } else if (msg.type === "step") {
      markStepDone(msg.id);
      updateActiveStep();
    } else if (msg.type === "done") {
      // Ferme l'EventSource (plus rien à streamer)
      if (es) { es.close(); es = null; }
      // Marque que la complétion s'est faite en live → trigger le modal
      liveCompletion = true;
      onComplete();
    }
  });

  // ----- Stop (robuste) ----------------------------------------------------
  stopBtn.addEventListener("click", async () => {
    if (!confirm("Arrêter le bootstrap en cours ?")) return;

    stopBtn.disabled = true;
    const oldText = stopBtn.textContent;
    stopBtn.textContent = "Arrêt…";

    try {
      const r = await fetch(stopUrl, { method: "POST" });
      const j = await r.json().catch(() => ({}));

      if (!r.ok) {
        alert("Erreur côté serveur : " + (j.error || r.statusText));
        stopBtn.disabled = false;
        stopBtn.textContent = oldText;
        return;
      }

      // Fermer l'EventSource pour ne plus voir les "logs"
      if (es) { es.close(); es = null; }

      // Feedback visuel selon le statut renvoyé
      const status = j.status || "stopped";
      const signals = (j.signals_sent || []).join(", ");
      if (status === "not_running") {
        logStatus.textContent = "déjà arrêté";
      } else {
        logStatus.textContent = signals ? `arrêté (${signals.toLowerCase()})` : "arrêté";
      }
      logStatus.classList.remove("live");
      logStatus.classList.add("error");
      statusLine.textContent = "Bootstrap arrêté manuellement.";
      stopBtn.textContent = "Arrêté ✓";
    } catch (e) {
      alert("Erreur réseau : " + e.message);
      stopBtn.disabled = false;
      stopBtn.textContent = oldText;
    }
  });

  // ----- Modal : close ----------------------------------------------------
  function closeModal() {
    successModal.classList.add("hidden");
    // Une fois fermé manuellement, on affiche la section success en bas
    // pour garder les liens accessibles
    if (liveCompletion) {
      showStaticSuccess();
    }
  }
  successModal.querySelectorAll(".modal-close, .modal-close-btn").forEach(b => {
    b.addEventListener("click", closeModal);
  });
  // Click sur le fond (en dehors du modal-content) ferme aussi
  successModal.addEventListener("click", (e) => {
    if (e.target === successModal) closeModal();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !successModal.classList.contains("hidden")) {
      closeModal();
    }
  });

  // ----- Helpers -----------------------------------------------------------
  function appendLog(line) {
    if (firstChunk) {
      logOutput.textContent = "";
      firstChunk = false;
    }
    logOutput.textContent += line + "\n";
    logOutput.scrollTop = logOutput.scrollHeight;
  }

  function markStepDone(stepId) {
    const el = document.querySelector(`.step[data-step-id="${stepId}"]`);
    if (!el) return;
    el.classList.add("done");
    el.classList.remove("active");
    el.querySelector(".step-icon").textContent = "✓";
  }

  function updateActiveStep() {
    let firstPending = -1;
    for (let i = 0; i < steps.length; i++) {
      if (!steps[i].classList.contains("done")) {
        firstPending = i;
        break;
      }
    }
    if (firstPending === -1) return;
    steps.forEach((s, i) => {
      s.classList.toggle("active", i === firstPending);
    });
    const lbl = steps[firstPending].querySelector(".step-label").textContent;
    if (wasRunningAtLoad !== false) {  // n'écrase pas le message "déjà déployé"
      statusLine.textContent = "En cours : " + lbl;
    }
  }

  function buildLinks() {
    const text = logOutput.textContent;
    const repoMatch = text.match(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+/);
    const apiMatch = text.match(/http:\/\/[\w.\-]+\/api\/health/);

    const links = [];
    if (apiMatch) {
      const host = apiMatch[0].replace("/api/health", "");
      links.push(`<a href="${host}/" target="_blank">🌍 Application : ${host}/</a>`);
      links.push(`<a href="${apiMatch[0]}" target="_blank">♡ Health : ${apiMatch[0]}</a>`);
    }
    if (repoMatch) {
      links.push(`<a href="${repoMatch[0]}" target="_blank">⎇ Dépôt : ${repoMatch[0]}</a>`);
      links.push(`<a href="${repoMatch[0]}/actions" target="_blank">⚒ CI/CD</a>`);
    }
    if (!links.length) {
      links.push(`<em>Pas de liens trouvés dans les logs (le déploiement a peut-être été interrompu)</em>`);
    }
    return links.map(l => "<li>" + l + "</li>").join("");
  }

  function showStaticSuccess() {
    if (successBanner) successBanner.classList.remove("hidden");
    if (successSection) {
      successSection.classList.remove("hidden");
      successLinks.innerHTML = buildLinks();
    }
  }

  function onComplete() {
    const allDone = steps.every(s => s.classList.contains("done"));
    logStatus.textContent = allDone ? "terminé" : "interrompu";
    logStatus.classList.remove("live");
    logStatus.classList.add(allDone ? "done" : "error");

    statusLine.textContent = allDone
      ? "🎉 Bootstrap terminé avec succès"
      : "⚠ Bootstrap interrompu, voir les logs";
    stopBtn.disabled = true;
    stopBtn.textContent = allDone ? "Terminé ✓" : "Arrêté";

    if (allDone && liveCompletion) {
      // Transition running→done LIVE → modal (avec close)
      modalLinks.innerHTML = buildLinks();
      successModal.classList.remove("hidden");
    } else if (allDone) {
      // Cas safety net : déjà fini, on affiche juste la section
      showStaticSuccess();
    }
  }
})();
