const { fontFamily } = require('tailwindcss/defaultTheme');

/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./layouts/**/*.html', './content/**/*.md'],
  theme: {
    extend: {
      fontFamily: {
        mono: ['Fira Mono', 'Consolas', 'Monaco', 'Andale Mono', 'monospace'],
        sans: ['Fira Sans', 'sans-serif']
      },
      typography: (theme) => ({
        DEFAULT: {
          css: {
            'pre code': {
              fontFamily: 'Fira Mono'
            }
          }
        }
      })
    }
  },
  plugins: [require('@tailwindcss/typography')]
};

