// web/static/index.js — Liste des workspaces : gestion delete.
(() => {
  document.querySelectorAll('button[data-action="delete"]').forEach(btn => {
    btn.addEventListener("click", async () => {
      const name = btn.dataset.ws;
      if (!confirm(`Supprimer définitivement le workspace "${name}" ?\nLes credentials, l'état et le projet généré seront perdus.`)) return;

      btn.disabled = true;
      btn.textContent = "Suppression…";
      try {
        const r = await fetch(`/workspaces/${encodeURIComponent(name)}/delete`, { method: "POST" });
        if (r.ok) {
          const card = document.querySelector(`.ws-card[data-ws="${name}"]`);
          if (card) {
            card.style.transition = "opacity 0.3s";
            card.style.opacity = "0";
            setTimeout(() => location.reload(), 300);
          }
        } else {
          const j = await r.json();
          alert("Suppression refusée : " + (j.error || r.statusText));
          btn.disabled = false;
          btn.textContent = "Supprimer";
        }
      } catch (e) {
        alert("Erreur réseau : " + e.message);
        btn.disabled = false;
        btn.textContent = "Supprimer";
      }
    });
  });
})();
