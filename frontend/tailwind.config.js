module.exports = {
  content: ["./index.html", "./src/**/*.{gleam,mjs}"],
  theme: {
    extend: {
      animation: {
        foil: "foil 10s linear infinite",
      },
      keyframes: {
        foil: {
          "0%, 100%": { filter: "hue-rotate(0deg);" },
          "50%": { filter: "hue-rotate(180deg);" },
        },
      },
    },
  },
  plugins: [],
};
