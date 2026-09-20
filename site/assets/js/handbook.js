// Bixel Studio Handbook JavaScript (Procreate Inspired)

document.addEventListener('DOMContentLoaded', () => {
  // 1. Sidebar Scroll-Spy
  const chapters = document.querySelectorAll('.hb-chapter');
  const navLinks = document.querySelectorAll('.sidebar-item-link');

  const onScroll = () => {
    let currentId = '';
    const scrollPos = window.scrollY + 140;

    chapters.forEach((chapter) => {
      const top = chapter.offsetTop;
      const height = chapter.offsetHeight;
      if (scrollPos >= top && scrollPos < top + height) {
        currentId = chapter.getAttribute('id');
      }
    });

    navLinks.forEach((link) => {
      link.classList.remove('active');
      if (link.getAttribute('href') === `#${currentId}`) {
        link.classList.add('active');
      }
    });
  };

  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // 2. Search Filter
  const searchInput = document.getElementById('handbook-search');
  if (searchInput) {
    searchInput.addEventListener('input', (e) => {
      const query = e.target.value.toLowerCase().trim();
      const sidebarLinks = document.querySelectorAll('.sidebar-item-link');
      const groupTitles = document.querySelectorAll('.sidebar-group-title');

      if (!query) {
        sidebarLinks.forEach(link => link.parentElement.style.display = '');
        groupTitles.forEach(title => title.style.display = '');
        return;
      }

      sidebarLinks.forEach(link => {
        const text = link.textContent.toLowerCase();
        const matches = text.includes(query);
        link.parentElement.style.display = matches ? '' : 'none';
      });

      groupTitles.forEach(title => {
        const nextList = title.nextElementSibling;
        if (nextList && nextList.tagName === 'UL') {
          const visibleItems = nextList.querySelectorAll('li:not([style*="display: none"])');
          title.style.display = visibleItems.length > 0 ? '' : 'none';
        }
      });
    });
  }

  // 3. Realtime GitHub Stars Loader
  const repo = 'ajithberlin/bixel-native';
  const cacheKey = `gh_stars_${repo}`;
  const starCountEls = document.querySelectorAll('.github-stars-count');

  const updateStarsUI = (count) => {
    starCountEls.forEach((el) => {
      el.textContent = count;
      el.style.display = 'inline-flex';
    });
  };

  const cachedStars = sessionStorage.getItem(cacheKey);
  if (cachedStars) {
    updateStarsUI(cachedStars);
  }

  fetch(`https://api.github.com/repos/${repo}`)
    .then((res) => {
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    })
    .then((data) => {
      if (typeof data.stargazers_count === 'number') {
        const count = data.stargazers_count >= 1000
          ? (data.stargazers_count / 1000).toFixed(1).replace(/\.0$/, '') + 'k'
          : data.stargazers_count.toString();
        sessionStorage.setItem(cacheKey, count);
        updateStarsUI(count);
      }
    })
    .catch((err) => {
      if (!cachedStars) {
        starCountEls.forEach(el => el.style.display = 'none');
      }
    });
});
