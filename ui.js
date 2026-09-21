document.addEventListener('DOMContentLoaded',async()=>{
  const buttons=[...document.querySelectorAll('nav button')], views=[...document.querySelectorAll('.view')];
  buttons.forEach(button=>button.addEventListener('click',()=>{
    views.forEach(view=>view.classList.toggle('active',view.id===button.dataset.view));
    buttons.forEach(item=>item.classList.toggle('active',item===button));
  }));
  const {createClient}=await import('https://esm.sh/@supabase/supabase-js@2');
  const db=createClient('https://mdrrnanxqazecqviaass.supabase.co','sb_publishable_ylMIgpLXA0NBoeb3aPI8qQ_m0wrG7It');
  const auth=document.querySelector('#auth'), signedOut=document.querySelector('#signedOut'), signedIn=document.querySelector('#signedIn');
  function showAccess(session){
    const email=session?.user?.email;
    auth.textContent=email?`Commissioner · ${email}`:'Public view';
    signedOut.hidden=Boolean(email); signedIn.hidden=!email;
    if(email) document.querySelector('#signedInEmail').textContent=`Signed in as ${email}. You can now make league changes.`;
  }
  const {data:{session}}=await db.auth.getSession(); showAccess(session);
  db.auth.onAuthStateChange((_event,nextSession)=>showAccess(nextSession));
  document.querySelector('#magic')?.addEventListener('click',async()=>{
    const button=document.querySelector('#magic'); button.disabled=true; button.textContent='Signing in…';
    const {error}=await db.auth.signInWithPassword({email:document.querySelector('#email').value.trim(),password:document.querySelector('#password').value});
    button.disabled=false; button.textContent='Sign in';
    if(error) alert(error.message);
  });
  document.querySelector('#signOut')?.addEventListener('click',async()=>{await db.auth.signOut();});
});
