/* =========================================================
   Supabase project connection.
   Replace these two values once your project exists —
   see SETUP.md. Until then, every page falls back to the
   bundled data below so the site still works out of the box.
   ========================================================= */
const SUPABASE_URL = "https://yiiijduxagjkmbzrhoaj.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlpaWlqZHV4YWdqa21ienJob2FqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM4Nzk2NzAsImV4cCI6MjA5OTQ1NTY3MH0.XIyRRrc-lh6mJqjGWZkflTYUFTZQwopPKeAm88Aze88";
const TIP_JAR_URL = "buymeacoffee.com/tigerdle";

function fnUrl(name){ return `${SUPABASE_URL}/functions/v1/${name}`; }

let sb = null;
try{
  if(window.supabase && !SUPABASE_URL.includes("YOUR-PROJECT-REF")){
    sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  }
}catch(e){ console.warn("Supabase not configured yet:", e); }

// Minimal no-op stand-in so calling code doesn't need to branch everywhere
// before the real project is wired up.
if(!sb){
  sb = {
    from(){
      const chain = {
        select(){ return chain; },
        eq(){ return chain; },
        order(){ return chain; },
        insert(){ return Promise.resolve({ error:{ message:"Supabase not configured yet" } }); },
        then(resolve){ resolve({ data:[], error:null }); return Promise.resolve({data:[],error:null}); }
      };
      return chain;
    }
  };
}

/* =========================================================
   Fallback player database — used whenever Supabase isn't
   configured yet, or a fetch fails/returns nothing. Keeps
   the game playable immediately, before any backend exists.
   Once the database has rows, those take over automatically.
   ========================================================= */
const FALLBACK_PLAYERS = [
  {first:"Ivor", last:"Pandur", pos:"GK", nat:"Croatia", era:"Current Squad", age:25},
  {first:"Dillon", last:"Phillips", pos:"GK", nat:"England", era:"Current Squad", age:30},
  {first:"Lewie", last:"Coyle", pos:"DF", nat:"England", era:"Current Squad", age:30},
  {first:"Cody", last:"Drameh", pos:"DF", nat:"England", era:"Current Squad", age:24},
  {first:"Akin", last:"Famewo", pos:"DF", nat:"England", era:"Current Squad", age:27},
  {first:"Ryan", last:"Giles", pos:"DF", nat:"Wales", era:"Current Squad", age:26},
  {first:"Semi", last:"Ajayi", pos:"DF", nat:"Nigeria", era:"Current Squad", age:32},
  {first:"John", last:"Egan", pos:"DF", nat:"Republic of Ireland", era:"Current Squad", age:33},
  {first:"Charlie", last:"Hughes", pos:"DF", nat:"England", era:"Current Squad", age:22},
  {first:"Brandon", last:"Williams", pos:"DF", nat:"Wales", era:"Current Squad", age:25},
  {first:"Matty", last:"Jacob", pos:"DF", nat:"Unknown", era:"Current Squad", age:24},
  {first:"Zane", last:"Myers", pos:"DF", nat:"Unknown", era:"Current Squad", age:20},
  {first:"John", last:"Lundstram", pos:"MF", nat:"England", era:"Current Squad", age:31},
  {first:"Regan", last:"Slater", pos:"MF", nat:"England", era:"Current Squad", age:26},
  {first:"Amir", last:"Hadžiahmetović", pos:"MF", nat:"Bosnia & Herzegovina", era:"Current Squad", age:28},
  {first:"Kasey", last:"Palmer", pos:"MF", nat:"England", era:"Current Squad", age:29},
  {first:"Matty", last:"Crooks", pos:"MF", nat:"England", era:"Current Squad", age:32},
  {first:"Liam", last:"Millar", pos:"MF", nat:"Canada", era:"Current Squad", age:26},
  {first:"Joe", last:"Gelhardt", pos:"MF", nat:"England", era:"Current Squad", age:23},
  {first:"Bachir", last:"Belloumi", pos:"MF", nat:"Algeria", era:"Current Squad", age:23},
  {first:"Yu", last:"Hirakawa", pos:"MF", nat:"Japan", era:"Current Squad", age:25},
  {first:"Darko", last:"Gyabi", pos:"MF", nat:"England", era:"Current Squad", age:21},
  {first:"Eliot", last:"Matazo", pos:"MF", nat:"Belgium", era:"Current Squad", age:23},
  {first:"Oliver", last:"McBurnie", pos:"FW", nat:"Scotland", era:"Current Squad", age:29},
  {first:"Kyle", last:"Joseph", pos:"FW", nat:"England", era:"Current Squad", age:24},
  {first:"Enis", last:"Destan", pos:"FW", nat:"Turkey", era:"Current Squad", age:23},
  {first:"Babajide", last:"Akintola", pos:"FW", nat:"Unknown", era:"Current Squad", age:30},
  {first:"Dean", last:"Windass", pos:"FW", nat:"England", era:"2008 Promotion Hero", age:null},
  {first:"Ian", last:"Ashbee", pos:"MF", nat:"England", era:"2000s Captain, 4 Divisions", age:null},
  {first:"Nick", last:"Barmby", pos:"MF", nat:"England", era:"2000s Local Hero", age:null},
  {first:"Jimmy", last:"Bullard", pos:"MF", nat:"England", era:"Premier League Era", age:null},
  {first:"Boaz", last:"Myhill", pos:"GK", nat:"Wales", era:"2000s", age:null},
  {first:"Michael", last:"Turner", pos:"DF", nat:"England", era:"2000s", age:null},
  {first:"Andy", last:"Dawson", pos:"DF", nat:"England", era:"2000s-2010s One-Club Man", age:null},
  {first:"Stuart", last:"Elliott", pos:"FW", nat:"Northern Ireland", era:"2000s Goal Machine", age:null},
  {first:"Geovanni", last:"Geovanni", pos:"MF", nat:"Brazil", era:"2008 Premier League Magician", age:null},
  {first:"Ken", last:"Wagstaff", pos:"FW", nat:"England", era:"1960s Golden Era", age:null},
  {first:"Chris", last:"Chilton", pos:"FW", nat:"England", era:"1960s-70s All-Time Top Scorer", age:null},
  {first:"Kamil", last:"Grosicki", pos:"MF", nat:"Poland", era:"2016-2020 Fan Favourite", age:null},
  {first:"Curtis", last:"Davies", pos:"DF", nat:"England", era:"2021 League One Title Captain", age:null},
  {first:"Jarrod", last:"Bowen", pos:"FW", nat:"England", era:"2014-2019 Academy Graduate", age:null},
  {first:"Robert", last:"Snodgrass", pos:"MF", nat:"Scotland", era:"2008-2012 Premier League", age:null},
  {first:"George", last:"Boateng", pos:"MF", nat:"Netherlands", era:"Premier League Era", age:null},
  {first:"Michael", last:"Dawson", pos:"DF", nat:"England", era:"2018-2022 Captain", age:null},
  {first:"Fraizer", last:"Campbell", pos:"FW", nat:"England", era:"2014-2018", age:null},
  {first:"Mohamed", last:"Diame", pos:"MF", nat:"France", era:"2014-2016", age:null},
  {first:"Nouha", last:"Dicko", pos:"FW", nat:"DR Congo", era:"2014-2018", age:null},
  {first:"Sone", last:"Aluko", pos:"FW", nat:"Nigeria", era:"2014-2016", age:null},
  {first:"Alex", last:"Bruce", pos:"DF", nat:"Republic of Ireland", era:"2012-2015", age:null},
  {first:"Liam", last:"Boyce", pos:"FW", nat:"Northern Ireland", era:"2021-2023", age:null},
  {first:"Callum", last:"Elder", pos:"DF", nat:"Australia", era:"2018-2023", age:null},
];

// Common EFL/English league club names, purely for the "Guess the Opponent"
// autocomplete list — factual club names, nothing copyrighted here.
const OPPONENT_CLUBS = [
  "Sheffield Wednesday","Sheffield United","Leeds United","Middlesbrough","Sunderland",
  "Norwich City","Ipswich Town","West Bromwich Albion","Coventry City","Stoke City",
  "Preston North End","Blackburn Rovers","Bristol City","Cardiff City","Swansea City",
  "Watford","Millwall","Queens Park Rangers","Derby County","Luton Town",
  "Oxford United","Portsmouth","Plymouth Argyle","Burnley","Charlton Athletic",
  "Wrexham","Birmingham City","Leicester City","Southampton","Bolton Wanderers",
  "Barnsley","Rotherham United","Wigan Athletic","Huddersfield Town","Nottingham Forest",
  "Arsenal","Chelsea","Liverpool","Manchester United","Manchester City","Tottenham Hotspur",
  "Newcastle United","Aston Villa","Everton","West Ham United","Brentford","Fulham",
  "Crystal Palace","Wolverhampton Wanderers","Brighton & Hove Albion","AFC Bournemouth"
];

/* =========================================================
   Deterministic daily seeding — same pool, same day, same
   puzzle for everyone. No backend required for this part.
   ========================================================= */
function dateKey(){
  const d = new Date();
  return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");
}
function hashStr(str){
  let h = 5381;
  for(let i=0;i<str.length;i++){ h = ((h*33) ^ str.charCodeAt(i)) >>> 0; }
  return h >>> 0;
}
function pickDaily(pool, salt){
  const idx = hashStr(dateKey()+"::"+salt) % pool.length;
  return pool[idx];
}
function stripAccents(s){ return s.normalize("NFD").replace(/[\u0300-\u036f]/g,""); }

function loadState(key, fallback){
  try{ const raw = localStorage.getItem(key); return raw ? JSON.parse(raw) : fallback; }
  catch(e){ return fallback; }
}
function saveState(key, val){ localStorage.setItem(key, JSON.stringify(val)); }
