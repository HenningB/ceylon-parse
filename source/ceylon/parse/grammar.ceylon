import ceylon.language.meta {
    _type = type
}
import ceylon.language.meta.model {
    Generic,
    Type,
    UnionType,
    ClassOrInterface
}
import ceylon.language.meta.declaration {
    FunctionOrValueDeclaration
}
import ceylon.collection {
    HashMap,
    HashSet
}

"A do-nothing annotation class for the `error` annotation"
shared final annotation class GrammarErrorConstructor()
        satisfies OptionalAnnotation<GrammarErrorConstructor, Annotated> {}

"We annotate some methods of a `ParseTree` object to indicate that those
 methods can construct an error version of symbols so we can build error
 reporting into the parse tree."
shared annotation GrammarErrorConstructor errorConstructor() =>
        GrammarErrorConstructor();

"A do-nothing annotation class for the `rule` annotation"
shared final annotation class GrammarRule()
        satisfies OptionalAnnotation<GrammarRule, Annotated> {}

"We annotate methods of a `ParseTree` object to indicate that those methods
 correspond to production rules"
shared annotation GrammarRule rule() => GrammarRule();

"A do-nothing annotation class for the `tokenizer` annotation."
shared final annotation class Tokenizer()
        satisfies OptionalAnnotation<Tokenizer, Annotated> {}

"Methods annotated with `tokenizer` take a sequence and return a token."
shared annotation Tokenizer tokenizer() => Tokenizer();

"Exception thrown when we need a bad token constructor but one isn't defined"
class BadTokenConstructorException()
        extends Exception("Could not construct invalid token") {}

shared class ProductionClause(shared Boolean variadic,
        shared Boolean once,
        shared Atom|ProductionClause *values)
        satisfies Iterable<Atom> {

    value localAtoms = {for (x in values) if (is Atom x) x};
    value productionClauses = {for (x in values) if (is ProductionClause x) x};
    value allIterables = productionClauses.chain({localAtoms});
    value atomIterator = allIterables.reduce<{Atom *}>((x,y) => x.chain(y));
    value allAtoms = HashSet{*atomIterator};

    shared actual Boolean contains(Object type) {
        return allAtoms.contains(type);
    }

    shared actual Iterator<Atom> iterator() => allAtoms.iterator();
}

"A rule. Specifies produced and consumed symbols and a method to execute them"
shared class Rule(shared Object(Object?*) consume,
        shared ProductionClause[] consumes,
        shared Atom produces) {
    shared actual Integer hash = consumes.hash ^ 2 + produces.hash;

    shared actual Boolean equals(Object other) {
        if (is Rule other) {
            return other.consumes == consumes && other.produces == produces;
        } else {
            return false;
        }
    }
}

"Break a type down into type atoms or aggregate producion clauses"
ProductionClause|Atom makeTypeAtom(Type p, Boolean f, Boolean once) {
    if (is UnionType p) {
        return ProductionClause(f, once, *{for (t in p.caseTypes)
            makeTypeAtom(t, false, false)});
    } else {
        return Atom(p);
    }
}

"Turn a type into a production clause"
ProductionClause makeProductionClause(Type p, FunctionOrValueDeclaration f) {
    ProductionClause|Atom x;
    Boolean once;

    if (f.variadic) {
        assert(is ClassOrInterface p);
        assert(exists sub = p.typeArguments.items.first);
        once = p.declaration == `interface Sequence`;
        x = makeTypeAtom(sub, true, once);
    } else {
        once = false;
        x = makeTypeAtom(p, false, false);
    }

    if (is Atom x) {
        return ProductionClause(f.variadic, once, x);
    } else {
        return x;
    }
}

"A [[Grammar]] is defined by a series of BNF-style production rules. The rules
 are specifed by defining methods with the `rule` annotation.  The parser will
 create an appropriate production rule and call the annotated method in order
 to reduce the value."
shared abstract class Grammar<out Root, Data>()
        given Root satisfies Object {
    "A list of rules for this grammar"
    shared variable Rule[] rules = [];

    "The result symbol we expect from this tree"
    shared Atom result = Atom(`Root`);

    "Error constructors"
    shared HashMap<Atom, Object(Object?, Object?)> errorConstructors =
        HashMap<Atom, Object(Object?, Object?)>();

    "Tokenizers"
    shared variable HashMap<Atom, Token?(Data, Object?)> tokenizers =
    HashMap<Atom, Token?(Data, Object?)>();

    variable Boolean populated = false;

    "Set up the list of rules"
    shared void populateRules() {
        if (populated) { return; }
        populated = true;

        value meths = _type(this).getMethods<Nothing>(`GrammarRule`);
        value errConMeths =
            _type(this).getMethods<Nothing>(`GrammarErrorConstructor`);
        value tokenizerMeths = _type(this).getMethods<Nothing>(`Tokenizer`);

        for (t in tokenizerMeths) {
            Token? tokenizer(Data s, Object? last) {
                assert(is Token? ret = t.declaration.memberInvoke(this, [],
                            s, last));
                return ret;
            }

            assert(is UnionType retType = t.type);
            value caseTypes =  retType.caseTypes;
            assert(caseTypes.size == 2);
            assert(is Generic tokenType = {for (r in caseTypes) if (
                        !r.typeOf(null)) r}.first);

            value typeArgs = tokenType.typeArguments.items;
            assert(typeArgs.size == 1);
            assert(exists type = typeArgs.first);

            tokenizers.put(Atom(type), tokenizer);
        }

        for (c in errConMeths) {
            Object construct(Object? o, Object? prev) {
                assert(is Object ret = c.declaration.memberInvoke(this, [],
                            o, prev));
                return ret;
            }

            errorConstructors.put(Atom(c.type), construct);
        }

        for (r in meths) {
            Object consume(Object? *o) {
                assert(is Object ret = r.declaration.memberInvoke(this, [], *o));
                return ret;
            }

            value params = zipPairs(r.parameterTypes,
                    r.declaration.parameterDeclarations);
            value consumes = [ for (p in params) makeProductionClause(*p) ];
            value produces = Atom(r.type);

            value rule = Rule(consume, consumes, produces);

            rules = rules.withTrailing(rule);
        }
    }

    "Returns a token to represent an unparseable region. The input data is
     exactly the contents of that region."
    shared default Object badTokenConstructor(Data data, Object? previous) {
        throw BadTokenConstructorException();
    }
}
