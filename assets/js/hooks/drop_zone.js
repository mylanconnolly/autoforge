const DropZone = {
  mounted() {
    this.el.addEventListener("dragover", (e) => {
      e.preventDefault();
      this.el.classList.add("border-primary", "bg-primary/5");
      this.el.classList.remove("border-base-300");
    });

    this.el.addEventListener("dragleave", () => {
      this.el.classList.remove("border-primary", "bg-primary/5");
      this.el.classList.add("border-base-300");
    });

    this.el.addEventListener("drop", () => {
      this.el.classList.remove("border-primary", "bg-primary/5");
      this.el.classList.add("border-base-300");
    });
  },
};

export default DropZone;
