# Intro {toggle="true"}
- Hey, I'm Mike from **Convex**, and today we're building a live leaderboard
- It updates in real time, with no polling and no websockets to wire up
    - Show the finished app first
    - Point out the scores changing
<callout icon="💡" color="gray_bg">
    Switch to the code editor
</callout>
# The schema
- Everything starts with the schema in `convex/schema.ts`
- A table for players and a table for scores
    - Scores have an index on the game and the value
- Then one query reads the top ten
